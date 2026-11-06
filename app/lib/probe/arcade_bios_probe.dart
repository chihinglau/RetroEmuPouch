import 'dart:convert';
import 'dart:io';

import 'package:archive/archive.dart';
import 'package:flutter/services.dart';

import '../pal/platform_pal.dart';

/// Headless arcade BIOS compatibility probe (OHOS / Pura70).
///
/// Enabled ONLY with `--dart-define=GP_BIOS_PROBE=true`. `hdc` cannot write
/// into the app sandbox, and the Flutter/Dart process cannot read
/// `/data/local/tmp` (SELinux), so each A/B scenario is baked into the HAP at
/// build time with `--dart-define=GP_BIOS_CMD=tag=..;rom=..;drop=1;...`.
/// The probe performs the reversible file mutations itself, launches one ROM
/// through the normal PAL path, waits for MAME to verify its ROM set, and
/// writes `<filesDir>/bios_probe.txt` with the native core's own diagnostics.
/// Read it back with:
///
///   hdc shell -b com.retroemupouch.app cat \
///     /data/app/el2/100/base/com.retroemupouch.app/files/bios_probe.txt
///
/// Every mutation is reversible: `backup` keeps `<name>.gpbak`, `drop` renames
/// to `<name>.gpoff` (the staging code only looks for exact `.zip` names), and
/// `restore` puts everything back.
///
/// For the `priva=1` scenario the probe rebuilds `neogeo.zip` itself: the ONLY
/// compiled-in bytes are the 128 KB GPL-3.0 PrivaBIOS asset, and every other
/// ZIP member is read from the user's own on-device `neogeo.zip.gpbak`. No
/// copyrighted BIOS/ROM bytes are compiled into the app or committed to this
/// repository. Production HAPs carry just `.gitkeep` in `assets/probe/`.
const bool kArcadeBiosProbe = bool.fromEnvironment('GP_BIOS_PROBE');
const String kBiosProbeCmd =
    String.fromEnvironment('GP_BIOS_CMD', defaultValue: '');
const String kBiosProbeReport = 'bios_probe.txt';
const String _bakSuffix = '.gpbak';
const String _offSuffix = '.gpoff';

const List<String> _backupPaths = <String>[
  'system/qsound.zip',
  'system/qsound_hle.zip',
  'system/neogeo.zip',
];

// The PrivaBIOS scenario overwrites all three neogeo.zip rompath copies, so all
// three must be restorable by the F-restore scenario.
const List<String> _privaBackupPaths = <String>[
  ..._backupPaths,
  'system/mame/roms/neogeo.zip',
  'rom_cache/mame/neogeo.zip',
];

const String _privaAsset = 'assets/probe/privabios.rom';
const List<String> _privaTargets = <String>[
  'system/neogeo.zip',
  'system/mame/roms/neogeo.zip',
  'rom_cache/mame/neogeo.zip',
];

// Every rompath gpretro.cpp StageArcadeContent can look in.
const List<String> _qsoundPaths = <String>[
  'system/qsound.zip',
  'system/qsound_hle.zip',
  'system/mame/roms/qsound.zip',
  'system/mame/roms/qsound_hle.zip',
  'rom_cache/mame/qsound.zip',
  'rom_cache/mame/qsound_hle.zip',
];

// qsound_hle.zip is a byte-identical duplicate of qsound.zip in this project.
const List<String> _qsoundHlePaths = <String>[
  'system/qsound_hle.zip',
  'system/mame/roms/qsound_hle.zip',
  'rom_cache/mame/qsound_hle.zip',
];

Map<String, dynamic> _cfgFromCmd() {
  final c = <String, String>{};
  for (final part in kBiosProbeCmd.split(';')) {
    final i = part.indexOf('=');
    if (i > 0) {
      c[part.substring(0, i).trim()] = part.substring(i + 1).trim();
    }
  }
  final copyFrom = c['copyFrom'];
  final copyTo = c['copyTo'];
  final priva = c['priva'] == '1';
  final dropPaths = c['drop'] == '1'
      ? _qsoundPaths
      : (c['dropHle'] == '1' ? _qsoundHlePaths : const <String>[]);
  return <String, dynamic>{
    'tag': c['tag'] ?? 'cmd',
    'rom': c['rom'] ?? 'roms/peer/dino.zip',
    'core': c['core'] ?? 'mame',
    'platform': c['platform'] ?? 'mame',
    'settleMs': int.tryParse(c['settleMs'] ?? '') ?? 12000,
    'backup': priva ? _privaBackupPaths : _backupPaths,
    'restore': c['restore'] == '1',
    'priva': priva,
    'drop': dropPaths,
    'copy': (copyFrom != null && copyTo != null)
        ? <Map<String, String>>[
            <String, String>{'from': copyFrom, 'to': copyTo}
          ]
        : <Map<String, String>>[],
  };
}

/// Rebuilds the on-device `neogeo.zip` with PrivaBIOS as `sp-s2.sp1`.
///
/// Only the 128 KB GPL-3.0 asset is compiled into the probe HAP; every other
/// member comes from the user's own backup of their local BIOS bundle. The
/// rebuilt archive is written to all three rompaths the OHOS staging code
/// consults, so a stale copy can never shadow the swapped BIOS.
Future<void> _applyPrivaBios(String dir, void Function(String) log) async {
  final asset = await rootBundle.load(_privaAsset);
  final bios = Uint8List.view(
      asset.buffer, asset.offsetInBytes, asset.lengthInBytes);
  log('priva.asset.bytes=${bios.length}');
  if (bios.length != 128 * 1024) {
    throw StateError('unexpected PrivaBIOS size: ${bios.length}');
  }

  final backup = File('$dir/system/neogeo.zip.gpbak');
  if (!await backup.exists()) {
    throw StateError('missing original neogeo.zip backup');
  }
  final original = await backup.readAsBytes();
  final decoded = ZipDecoder().decodeBytes(original);
  // ZipDecoder().files is unmodifiable — build a fresh Archive instead.
  final rebuilt = Archive();
  var found = false;
  var oldSize = 0;
  for (final f in decoded.files) {
    if (f.name.toLowerCase() == 'sp-s2.sp1') {
      oldSize = f.size;
      rebuilt.addFile(ArchiveFile(f.name, bios.length, bios));
      found = true;
    } else {
      rebuilt.addFile(ArchiveFile(f.name, f.size, f.content));
    }
  }
  if (!found) throw StateError('sp-s2.sp1 not found in neogeo.zip');
  log('priva.sp-s2.sp1 oldBytes=$oldSize newBytes=${bios.length} '
      'members=${decoded.files.length}');

  final encoded = ZipEncoder().encode(rebuilt);
  if (encoded == null) throw StateError('ZipEncoder returned no data');
  final bytes = Uint8List.fromList(encoded);
  log('priva.zip originalBytes=${original.length} rebuiltBytes=${bytes.length}');
  for (final rel in _privaTargets) {
    final dst = File('$dir/$rel');
    await dst.parent.create(recursive: true);
    await dst.writeAsBytes(bytes, flush: true);
    log('priva.write $rel ${await dst.length()}');
  }
}

Future<void> runArcadeBiosProbe(PlatformPal pal) async {
  final lines = <String>[];
  void log(String s) {
    lines.add(s);
    // ignore: avoid_print
    print('[bios-probe] $s');
  }

  String dir = '';
  try {
    dir = await pal.filesDir();
    log('filesDir=$dir');
    log('started=${DateTime.now().toIso8601String()}');
    log('cmd=$kBiosProbeCmd');

    // Diagnostics: confirm why /data/local/tmp cannot be used as a control
    // channel (hdc -b can read it, but the Flutter process cannot).
    try {
      final d = Directory('/data/local/tmp');
      log('tmp.exists=${d.existsSync()} '
          'entries=${d.existsSync() ? d.listSync().length : -1}');
    } catch (e) {
      log('tmp.stat.error=$e');
    }
    try {
      log('tmp.json.readLen=${File('/data/local/tmp/gp_bios_probe.json').readAsStringSync().length}');
    } catch (e) {
      log('tmp.json.error=$e');
    }

    final cfg = _cfgFromCmd();
    log('control=${jsonEncode(cfg)}');
    final tag = cfg['tag'] as String;
    log('tag=$tag');

    String abs(String rel) => rel.startsWith('/') ? rel : '$dir/$rel';

    // Snapshot the BIOS files the host wants to be able to restore later.
    for (final rel in (cfg['backup'] as List<dynamic>? ?? <dynamic>[])) {
      final src = File(abs(rel as String));
      final bak = File('${src.path}$_bakSuffix');
      if (await src.exists() && !await bak.exists()) {
        await bak.writeAsBytes(await src.readAsBytes(), flush: true);
        log('backup $rel -> ${bak.path}');
      } else {
        log('backup $rel skipped (src=${await src.exists()} bak=${await bak.exists()})');
      }
    }

    if (cfg['restore'] == true) {
      final roots = <String>['$dir/system', '$dir/rom_cache/mame'];
      for (final root in roots) {
        final d = Directory(root);
        if (!await d.exists()) continue;
        await for (final e in d.list(recursive: true, followLinks: false)) {
          if (e is! File) continue;
          if (e.path.endsWith(_bakSuffix)) {
            final target = e.path.substring(0, e.path.length - _bakSuffix.length);
            await File(target).writeAsBytes(await e.readAsBytes(), flush: true);
            log('restored $target');
          } else if (e.path.endsWith(_offSuffix)) {
            await e.delete();
            log('removed ${e.path}');
          }
        }
      }
      log('restore.done=true');
      return;
    }

    // Take the named BIOS out of every rompath the native staging code uses.
    for (final rel in (cfg['drop'] as List<dynamic>? ?? <dynamic>[])) {
      final src = File(abs(rel as String));
      if (!await src.exists()) {
        log('drop $rel already absent');
        continue;
      }
      final off = File('${src.path}$_offSuffix');
      if (await off.exists()) await off.delete();
      await src.rename(off.path);
      log('drop $rel -> ${off.path}');
    }

    // Host-staged test BIOS (e.g. neogeo.zip with PrivaBIOS as sp-s2.sp1).
    for (final item in (cfg['copy'] as List<dynamic>? ?? <dynamic>[])) {
      final m = item as Map<String, dynamic>;
      final from = m['from'] as String;
      final to = m['to'] as String;
      final src = File(from);
      if (!await src.exists()) {
        log('copy SKIP missing=$from');
        continue;
      }
      final dst = File(abs(to));
      await dst.parent.create(recursive: true);
      await dst.writeAsBytes(await src.readAsBytes(), flush: true);
      log('copy $from -> $to (${await dst.length()} bytes)');
    }

    // OHOS PrivaBIOS scenario: rebuild neogeo.zip inside the app sandbox.
    if (cfg['priva'] == true) {
      await _applyPrivaBios(dir, log);
    }

    Future<void> snapshot(String label) async {
      for (final rel in <String>[
        'system/qsound.zip',
        'system/qsound_hle.zip',
        'system/neogeo.zip',
        'system/mame/roms/qsound.zip',
        'system/mame/roms/qsound_hle.zip',
        'system/mame/roms/neogeo.zip',
        'rom_cache/mame/qsound.zip',
        'rom_cache/mame/qsound_hle.zip',
        'rom_cache/mame/neogeo.zip',
      ]) {
        final f = File('$dir/$rel');
        final exists = await f.exists();
        log('$label $rel exists=$exists size=${exists ? await f.length() : 0}');
      }
    }

    await snapshot('pre');

    final rom = cfg['rom'] as String? ?? 'roms/peer/dino.zip';
    final core = cfg['core'] as String? ?? 'mame';
    final platform = cfg['platform'] as String? ?? 'mame';
    final romFile = File(abs(rom));
    log('target rom=$rom core=$core platform=$platform '
        'exists=${await romFile.exists()} '
        'size=${await romFile.exists() ? await romFile.length() : 0}');

    final launched = await pal.launchEmulator(
      relativePath: rom,
      coreId: core,
      platform: platform,
    );
    log('launch.ok=$launched');

    final settleMs = (cfg['settleMs'] as num?)?.toInt() ?? 12000;
    await Future<void>.delayed(Duration(milliseconds: settleMs));
    log('settled.afterMs=$settleMs');

    const ch = MethodChannel('gs/emulator');
    Future<String> diag(String method) async {
      try {
        final v = await ch.invokeMethod<dynamic>(method);
        return v?.toString() ?? '<null>';
      } catch (e) {
        return 'CHANNEL_ERROR=$e';
      }
    }

    // getLoadError(): '' == the core booted; JSON otherwise (reason/missing).
    log('getLoadError=${await diag('getLoadError')}');
    log('isCoreReady=${await diag('isCoreReady')}');
    log('getFps=${await diag('getFps')}');
    // Native core's own ROM/BIOS checksum warnings: "sp-s2.sp1 WRONG
    // CHECKSUMS" proves the PrivaBIOS replacement was actually loaded.
    log('getBiosWarnings=${await diag('getBiosWarnings')}');
    log('runningSaveKey=${await pal.runningSaveKey()}');
    await snapshot('post');

    final trace = File('$dir/emu_trace.txt');
    if (await trace.exists()) {
      final body = await trace.readAsString();
      log('emu_trace.tail=${body.split('\n').reversed.take(8).toList().reversed.join(' | ')}');
    }
    log('result.booted=${(await diag('getLoadError')).isEmpty}');
  } catch (e, st) {
    log('EXCEPTION=$e');
    log('STACK=$st');
  } finally {
    if (dir.isNotEmpty) {
      try {
        await File('$dir/$kBiosProbeReport')
            .writeAsString('${lines.join('\n')}\n', flush: true);
      } catch (_) {
        // best effort
      }
    }
  }
}
