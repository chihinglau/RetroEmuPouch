import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import '../features/settings/app_settings.dart';
import 'platform_pal.dart';

/// OpenHarmony / HarmonyOS NEXT implementation of [PlatformPal].
///
/// The Dart contract mirrors [AndroidPal] exactly — same channel names
/// (`gs/storage`, `gs/emulator`, `gs/updater`, `gs/netplay`) and same method
/// names — so that the native side (ArkTS/NAPI handlers, P3) slots in without
/// further Dart changes.
///
/// Until those NAPI handlers exist, every MethodChannel call here is wrapped in
/// a try/catch. A [MissingPluginException] is NOT a [PlatformException]
/// subclass (it merely `implements Exception`), so we catch broadly and return
/// a safe default instead of crashing — letting the pure-Dart UI (library list,
/// settings, …) render and be exercised on-device before the native layer lands.
class OhosPal implements PlatformPal {
  static const _storage = MethodChannel('gs/storage');
  static const _emulator = MethodChannel('gs/emulator');
  static const _updater = MethodChannel('gs/updater');
  static const _netplay = MethodChannel('gs/netplay');

  // Broadcast because the controller (and tests) may listen at different
  // times while the single OhosPal instance lives for the app's lifetime.
  final StreamController<NetplayPlayEnd> _playEnds =
      StreamController<NetplayPlayEnd>.broadcast();

  OhosPal() {
    _netplay.setMethodCallHandler((call) async {
      debugPrint('[OhosPal] gs/netplay received method=${call.method} args=${call.arguments}');
      if (call.method == 'playEnded' && call.arguments is Map) {
        try {
          final event = NetplayPlayEnd.fromMap(call.arguments as Map);
          debugPrint('[OhosPal] playEnded parsed roomId32=${event.roomId32} clean=${event.clean}');
          _playEnds.add(event);
        } catch (e) {
          debugPrint('[OhosPal] playEnded PARSE ERROR: $e');
        }
      } else {
        debugPrint('[OhosPal] playEnded DROPPED: method mismatch or args type=${call.arguments.runtimeType}');
      }
      return null;
    });
  }

  @override
  Stream<NetplayPlayEnd> get netplayPlayEnds => _playEnds.stream;

  @override
  Future<void> stopNetplay() async {
    try {
      await _netplay.invokeMethod('stop');
      debugPrint('[OhosPal] stopNetplay → native ok');
    } catch (e) {
      debugPrint('[OhosPal] stopNetplay native error: $e');
    }
  }

  @override
  bool get emulatorCoversFlutter => true;

  @override
  Future<String> filesDir() async {
    try {
      final r = await _storage.invokeMethod<String>('getFilesDir');
      if (r != null && r.isNotEmpty) return r;
    } catch (_) {
      // Native handler not wired yet (P3). Fall back to a safe existing dir so
      // the Dart UI can render; replaced once OhosPal native lands.
    }
    return Directory.systemTemp.path;
  }

  @override
  Future<String?> deviceModel() async {
    try {
      final m = await _storage.invokeMethod<String>('getDeviceModel');
      return (m == null || m.trim().isEmpty) ? null : m.trim();
    } catch (_) {
      return null;
    }
  }

  @override
  Future<int?> availableBytes() async {
    try {
      return await _storage.invokeMethod<int>('getAvailableBytes');
    } catch (_) {
      return null;
    }
  }

  @override
  Future<bool> acquireMulticastLock() async {
    try {
      return await _storage
              .invokeMethod<bool>('acquireMulticastLock') ??
          false;
    } catch (_) {
      return false;
    }
  }

  @override
  Future<bool> releaseMulticastLock() async {
    try {
      return await _storage
              .invokeMethod<bool>('releaseMulticastLock') ??
          false;
    } catch (_) {
      return false;
    }
  }

  @override
  Future<String?> runningSaveKey() async {
    try {
      return await _storage.invokeMethod<String>('getRunningSaveKey');
    } catch (_) {
      return null;
    }
  }

  @override
  Future<ImportedRom?> importRomViaSaf({String mime = '*/*'}) async {
    try {
      final res =
          await _storage.invokeMethod<dynamic>('importRomViaSaf', jsonEncode({'mime': mime}));
      if (res == null) return null;
      return ImportedRom.fromMap(res as Map<dynamic, dynamic>);
    } catch (_) {
      return null;
    }
  }

  @override
  Future<ImportedPackage?> importPackageViaSaf() async {
    try {
      final res = await _storage.invokeMethod<dynamic>('importPackageViaSaf');
      if (res == null) return null;
      return ImportedPackage.fromMap(res as Map<dynamic, dynamic>);
    } catch (_) {
      return null;
    }
  }

  @override
  Future<String?> importBiosViaSaf() async {
    try {
      final res = await _storage.invokeMethod<dynamic>('importBiosViaSaf');
      return res as String?;
    } catch (_) {
      return null;
    }
  }

  @override
  Future<List<String>> importBiosBatchViaSaf() async {
    try {
      final res =
          await _storage.invokeMethod<dynamic>('importBiosBatchViaSaf');
      if (res == null) return const <String>[];
      return (res as List).map((e) => e as String).toList();
    } catch (_) {
      return const <String>[];
    }
  }

  @override
  Future<bool?> exportBiosZipViaSaf() async {
    try {
      return await _storage.invokeMethod<bool>('exportBiosZipViaSaf');
    } catch (_) {
      return false;
    }
  }

  @override
  Future<bool> deleteBios(String name) async {
    try {
      final ok =
          await _storage.invokeMethod<bool>('deleteBios', jsonEncode({'name': name}));
      return ok ?? false;
    } catch (_) {
      return false;
    }
  }

  @override
  Future<bool> exportPackageViaSaf({
    required String sourcePath,
    required String suggestedName,
  }) async {
    try {
      final ok = await _storage.invokeMethod<bool>('exportPackageViaSaf',
          jsonEncode({'sourcePath': sourcePath, 'suggestedName': suggestedName}));
      return ok ?? false;
    } catch (_) {
      return false;
    }
  }

  @override
  Future<ImportedMovesConfig?> importMovesConfigViaSaf() async {
    try {
      final res =
          await _storage.invokeMethod<dynamic>('importMovesConfigViaSaf');
      if (res == null) return null;
      return ImportedMovesConfig.fromMap(res as Map<dynamic, dynamic>);
    } catch (_) {
      return null;
    }
  }

  @override
  Future<bool> exportMovesConfigViaSaf({
    required String sourcePath,
    required String suggestedName,
  }) async {
    try {
      final ok = await _storage.invokeMethod<bool>('exportMovesConfigViaSaf',
          jsonEncode({'sourcePath': sourcePath, 'suggestedName': suggestedName}));
      return ok ?? false;
    } catch (_) {
      return false;
    }
  }

  @override
  Future<ImportedPadConfig?> importPadConfigViaSaf() async {
    try {
      final res =
          await _storage.invokeMethod<dynamic>('importPadConfigViaSaf');
      if (res == null) return null;
      return ImportedPadConfig.fromMap(res as Map<dynamic, dynamic>);
    } catch (_) {
      return null;
    }
  }

  @override
  Future<bool> exportPadConfigViaSaf({
    required String sourcePath,
    required String suggestedName,
  }) async {
    try {
      final ok = await _storage.invokeMethod<bool>('exportPadConfigViaSaf',
          jsonEncode({'sourcePath': sourcePath, 'suggestedName': suggestedName}));
      return ok ?? false;
    } catch (_) {
      return false;
    }
  }

  @override
  Future<bool> launchEmulator({
    required String relativePath,
    required String coreId,
    required String platform,
    Map<String, dynamic>? netplay,
  }) async {
    try {
      // Pass a single JSON string: the OHOS MethodChannel reliably delivers a
      // scalar argument, whereas a Map argument is not decoded into the plugin.
      //
      // We also mirror the Android native side's `applyPersistedSettings()`
      // (see android-ui-spec §16.5): the shared Flutter SettingsSheet writes
      // the virtual-pad config into `AppSettings`, and OHOS native reads it at
      // launch. Because the OHOS pad persists its config in `settings.json`
      // (not FlutterSharedPreferences.xml), we serialize the pad config here and
      // let GamePouchPlugin.ets stamp it into settings.json before the emulator
      // surface is created — so the Settings screen actually drives the pad.
      // Resume: read the last save slot persisted by the native emulator and
      // forward it so a re-launch of the same ROM auto-loads the most recent
      // state (parallels Android's flutter.lastSaveSlot auto-resume; only when
      // 「记住上次进度」 is enabled).
      Map<String, dynamic> resume = {
        'rememberLastGame': AppSettings.current.rememberLastGame,
        'slot': -1,
        'crc': '',
      };
      if (AppSettings.current.rememberLastGame) {
        try {
          final dir = await filesDir();
          final f = File('$dir/last_slot.json');
          if (f.existsSync()) {
            final m = jsonDecode(await f.readAsString()) as Map<String, dynamic>;
            resume = {
              'rememberLastGame': true,
              'slot': (m['slot'] is int) ? m['slot'] as int : -1,
              'crc': (m['crc'] is String) ? m['crc'] as String : '',
            };
          }
        } catch (_) {
          // Missing/corrupt: fall back to no-resume.
        }
      }
      final payload = jsonEncode({
        'rom': relativePath,
        'core': coreId,
        'platform': platform,
        'netplay': netplay,
        'pad': {
          'stickMode': AppSettings.current.stickMode,
          'stickDeadzone': AppSettings.current.stickDeadzone,
          'useDpadUi': AppSettings.current.useDpadUi,
          'padScale': AppSettings.current.padScale,
          'padOffsetX': AppSettings.current.padOffsetX,
          'padOffsetY': AppSettings.current.padOffsetY,
        },
        'prefs': {
          'showFpsHud': AppSettings.current.showFpsHud,
          'highRefreshRate': AppSettings.current.highRefreshRate,
          'fastForwardAudio': AppSettings.current.fastForwardAudio,
        },
        'resume': resume,
      });
      final ok = await _emulator.invokeMethod<bool>('launch', payload);
      return ok ?? false;
    } catch (_) {
      return false;
    }
  }

  @override
  Future<AppVersion> appVersion() async {
    try {
      final m = await _updater.invokeMethod<dynamic>('getVersion')
          as Map<dynamic, dynamic>;
      return AppVersion(
        versionCode: (m['versionCode'] as num?)?.toInt() ?? 0,
        versionName: m['versionName'] as String? ?? '',
      );
    } catch (_) {
      return AppVersion(versionCode: 0, versionName: '');
    }
  }

  @override
  Future<bool> installApk(String absolutePath) async {
    // HAP, not APK, on OpenHarmony. The P3 native handler decides behavior
    // (e.g. invoke the system installer via want/startAbility).
    try {
      final ok = await _updater
          .invokeMethod<bool>('installApk', {'path': absolutePath});
      return ok ?? false;
    } catch (_) {
      return false;
    }
  }

  @override
  Future<void> openStore() async {
    try {
      await _updater.invokeMethod('openStore');
    } catch (_) {
      // best-effort; ignore when no store handler exists
    }
  }

  // ---- app settings persistence (shared_preferences has no OHOS handler) ----
  // shared_preferences is a no-op on OHOS (no native handler), so AppSettings
  // would reset to defaults on every launch. Persist the snapshot to
  // `<filesDir>/app_prefs.json` instead — the same sandbox the native emulator
  // and the library already read/write, so it survives across launches.
  @override
  Future<Map<String, Object>?> loadAppSettings() async {
    try {
      final dir = await filesDir();
      final f = File('$dir/app_prefs.json');
      if (!f.existsSync()) return null;
      final j = jsonDecode(await f.readAsString());
      if (j is Map) return j.cast<String, Object>();
    } catch (_) {
      // Missing/corrupt file: caller falls back to defaults.
    }
    return null;
  }

  @override
  Future<void> saveAppSettings(Map<String, Object> data) async {
    try {
      final dir = await filesDir();
      final f = File('$dir/app_prefs.json');
      await f.writeAsString(jsonEncode(data), flush: true);
    } catch (_) {
      // Best-effort; settings stay in memory this session.
    }
  }
}
