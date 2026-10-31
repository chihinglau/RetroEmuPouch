import 'dart:async';

import 'package:flutter/services.dart';

import '../domain/rom_entry.dart';

/// Result of a SAF import, mirroring the Kotlin map.
class ImportedRom {
  ImportedRom({
    required this.name,
    required this.originalName,
    required this.relativePath,
    required this.size,
    required this.crc32,
  });

  final String name;
  final String originalName;
  final String relativePath;
  final int size;
  final int crc32;

  factory ImportedRom.fromMap(Map<dynamic, dynamic> m) => ImportedRom(
        name: m['name'] as String,
        originalName: m['originalName'] as String,
        relativePath: m['relativePath'] as String,
        size: (m['size'] as num).toInt(),
        crc32: (m['crc32'] as num).toInt(),
      );

  RomEntry toEntry() => RomEntry(
        name: name,
        originalName: originalName,
        relativePath: relativePath,
        size: size,
        crc32: crc32,
        importedAt: DateTime.now(),
      );
}

/// Result of a SAF package/ZIP pick: the native side copied the chosen file
/// into `filesDir/import_cache` and returns its on-device path so Dart can
/// parse (and auto-detect rom vs gamepouch resource package) with `archive`.
class ImportedPackage {
  ImportedPackage({required this.path, required this.name, required this.size});

  final String path;
  final String name;
  final int size;

  factory ImportedPackage.fromMap(Map<dynamic, dynamic> m) => ImportedPackage(
        path: m['path'] as String,
        name: m['name'] as String,
        size: (m['size'] as num).toInt(),
      );
}

/// Result of a SAF `moves.json` import pick. The native side copies the
/// chosen file into `filesDir/library/imports/` (a quarantined folder that
/// the editor is free to read and either accept into the live
/// `library/moves.json` or discard) and pre-checks that it parses as a
/// JSON object so the editor never sees half-baked data.
///
/// `ok = false` means the file was copied but isn't valid JSON; the
/// editor surfaces this as a user-visible error and the caller should
/// ignore [path] in that case.
class ImportedMovesConfig {
  ImportedMovesConfig({
    required this.path,
    required this.name,
    required this.size,
    required this.ok,
  });

  final String path;
  final String name;
  final int size;

  /// True when the copied file parsed as a JSON object. The editor still
  /// validates the *shape* (has `profiles`, etc.) — see
  /// `SpecialMovesConfig.fromJson`.
  final bool ok;

  factory ImportedMovesConfig.fromMap(Map<dynamic, dynamic> m) =>
      ImportedMovesConfig(
        path: m['path'] as String,
        name: m['name'] as String,
        size: (m['size'] as num).toInt(),
        ok: m['ok'] == true,
      );
}

/// Result of a SAF virtual-pad layout import pick. Mirrors [ImportedMovesConfig]:
/// the native side copies the chosen file into `filesDir/library/imports/` and
/// pre-checks it parses as a JSON object. The settings sheet then reads [path],
/// validates the `scale`/`offsetX`/`offsetY` fields, and adopts them.
class ImportedPadConfig {
  ImportedPadConfig({
    required this.path,
    required this.name,
    required this.size,
    required this.ok,
  });

  final String path;
  final String name;
  final int size;
  final bool ok;

  factory ImportedPadConfig.fromMap(Map<dynamic, dynamic> m) =>
      ImportedPadConfig(
        path: m['path'] as String,
        name: m['name'] as String,
        size: (m['size'] as num).toInt(),
        ok: m['ok'] == true,
      );
}

/// Platform abstraction: storage + emulator launch.
/// Android = native channels (see MainActivity.kt / EmulatorActivity.kt);
/// future ohos/ios/mock implementations slot in behind this interface.
class AppVersion {
  AppVersion({required this.versionCode, required this.versionName});
  final int versionCode;
  final String versionName;
}

/// Terminal event pushed by the native EmulatorActivity when a netplay
/// session ends there (clean exit vs drop/timeout/kill). [roomId32] is the
/// 32-bit room id carried in the native lockstep header (PlaySession.roomId32).
class NetplayPlayEnd {
  NetplayPlayEnd({required this.roomId32, required this.clean});

  final int roomId32;
  final bool clean;

  factory NetplayPlayEnd.fromMap(Map<dynamic, dynamic> m) => NetplayPlayEnd(
        // Kotlin Int may arrive negative; normalize to unsigned 32-bit to
        // match PlaySession.roomId32.
        roomId32: (m['roomId'] as num).toInt() & 0xFFFFFFFF,
        clean: m['clean'] == true,
      );
}

/// Platform abstraction: storage + emulator launch + OTA install.
/// Android = native channels (see MainActivity.kt / EmulatorActivity.kt);
/// future ohos/ios/mock implementations slot in behind this interface.
abstract interface class PlatformPal {
  /// Emits once per native netplay session teardown. The Dart PlaySession
  /// owner terminates the matching local session on these events so a stale
  /// "session in progress" can not block the next invite (Task 9).
  Stream<NetplayPlayEnd> get netplayPlayEnds;

  /// Requests the native layer to tear down any active netplay session.
  /// Dart→native direction (MethodChannel invokeMethod) is always reliable,
  /// so this is safe to call as a fallback when the reverse native→Dart
  /// `netplayPlayEnds` event fails to arrive (OHOS FlutterNapi silently
  /// drops MethodChannel invokeMethod messages from ArkTS). Returns once
  /// the native teardown has been initiated; does not wait for completion.
  Future<void> stopNetplay();

  /// True when the native emulator surface is pushed *inside* this app's own UI
  /// stack and therefore covers the Flutter engine (OpenHarmony: `router.pushUrl`
  /// puts the ArkUI `EmulatorSpike` page on top of the Flutter page).
  ///
  /// In that configuration the Flutter engine goes `paused → resumed` exactly
  /// when the emulator page is dismissed, so the Dart side can use that
  /// transition as a reliable "the emulator is gone" signal — the fallback that
  /// matters when the native → Dart `playEnded` event never arrives.
  bool get emulatorCoversFlutter => false;

  Future<String> filesDir();

  /// Manufacturer + model, used as the default 「发现伙伴」 display name.
  Future<String?> deviceModel();

  /// Free bytes on the filesDir partition (null when unavailable); used by
  /// the peer import space precheck.
  Future<int?> availableBytes();

  /// Hold/release the Wi-Fi multicast lock while the peers page is open so
  /// UDP discovery broadcasts are not filtered by the OS.
  Future<bool> acquireMulticastLock();
  Future<bool> releaseMulticastLock();

  /// CRC saveKey of the game currently running in the native emulator, or
  /// null when idle. Peer saves for this CRC are import-locked.
  Future<String?> runningSaveKey();
  Future<ImportedRom?> importRomViaSaf({String mime = '*/*'});

  /// Picks a single file via SAF and copies it verbatim into
  /// `<filesDir>/system/` (where libretro cores look up BIOS blobs such as
  /// `neogeo.zip`). Returns the stored file name, or null if the user cancels.
  /// Unlike [importRomViaSaf] this does NOT index the file as a playable game.
  Future<String?> importBiosViaSaf();

  /// Multi-pick variant of [importBiosViaSaf]: the user can select several
  /// BIOS blobs in one SAF round-trip and have them all staged into
  /// `<filesDir>/system/` at once. The list of stored names comes back
  /// verbatim so the caller can re-check `SystemFiles.missingForCore` and
  /// decide whether to prompt again. Empty list = user cancelled.
  Future<List<String>> importBiosBatchViaSaf();

  /// Bundles every BIOS currently in `<filesDir>/system/` into a single
  /// zip and lets the user save it via SAF (Downloads / USB / 云盘 / 微信文件).
  /// Returns true on success, false / null on cancel. The exported archive
  /// is round-trip safe: re-importing it via [importBiosBatchViaSaf] on a
  /// fresh phone restores the same names at the system root and the
  /// `LockedRom` mirror step stages them into every per-core subdir.
  Future<bool?> exportBiosZipViaSaf();

  /// Removes a single BIOS from `<filesDir>/system/` (and from any
  /// per-core subdir `LockedRom` had mirrored it into). Used by the
  /// settings page's "delete one" row so the user can rebuild their
  /// library without wiping the app.
  Future<bool> deleteBios(String name);

  /// Picks any file via SAF and copies it into `filesDir/import_cache`,
  /// returning its path so the caller can parse a gamepouch resource package
  /// or a plain ROM zip. Returns null when the user cancels.
  Future<ImportedPackage?> importPackageViaSaf();

  /// Streams [sourcePath] (a zip Dart built under filesDir) into a
  /// user-created SAF document. [suggestedName] seeds the create-dialog name.
  /// Returns true once written.
  Future<bool> exportPackageViaSaf({
    required String sourcePath,
    required String suggestedName,
  });

  /// Picks a JSON file via SAF, validates it as a `moves.json` payload and
  /// writes it into `<filesDir>/library/moves.json`. Returns the parsed
  /// config on success, or null when the user cancels. Invalid input
  /// surfaces as a thrown [PlatformException] with `code == "BAD_CONFIG"`.
  ///
  /// Used by the settings 「招式按键」 editor's import button so the user
  /// can swap a profile between machines (e.g. download a KOF98 preset on
  /// one phone and drop it onto another).
  Future<ImportedMovesConfig?> importMovesConfigViaSaf();

  /// Streams [sourcePath] (a `moves.json` Dart just wrote into filesDir)
  /// into a user-created SAF document so it can be shared offline. The
  /// caller passes the suggested filename (e.g. `moves-kof97.json`).
  Future<bool> exportMovesConfigViaSaf({
    required String sourcePath,
    required String suggestedName,
  });

  /// Picks a virtual-pad layout JSON via SAF and copies it into
  /// `filesDir/library/imports/`. Returns `{ path, name, size, ok }` (ok=true iff
  /// the file parses as a JSON object) for the settings sheet to validate and
  /// adopt (scale / offsetX / offsetY). Returns null when the user cancels.
  /// Default (null) implementation provided so test mocks need not override it.
  Future<ImportedPadConfig?> importPadConfigViaSaf() async => null;

  /// Streams [sourcePath] (a pad-layout JSON Dart just wrote into filesDir)
  /// into a user-created SAF document so it can be shared offline. The caller
  /// passes the suggested filename (e.g. `gamepouch_pad_layout.json`).
  /// Default (false) implementation provided so test mocks need not override it.
  Future<bool> exportPadConfigViaSaf({
    required String sourcePath,
    required String suggestedName,
  }) async =>
      false;

  /// Persisted [AppSettings] snapshot, used as a fallback store on platforms
  /// where `shared_preferences` has no native handler (OHOS). Returns the stored
  /// map, or null when nothing has been persisted yet. Default: null — platforms
  /// with a working shared_preferences keep using it directly and never call this.
  Future<Map<String, Object>?> loadAppSettings() async => null;

  /// Persists the [AppSettings] snapshot (see [loadAppSettings]). Default: no-op.
  Future<void> saveAppSettings(Map<String, Object> data) async {}

  /// [netplay] carries the lockstep session extras when launching a netplay
  /// game (role/peerIp/ports/sessionKey/roomId/bootstrapPort/...); null on
  /// the ordinary single-player path, which must stay byte-identical.
  Future<bool> launchEmulator({
    required String relativePath,
    required String coreId,
    required String platform,
    Map<String, dynamic>? netplay,
  });
  Future<AppVersion> appVersion();

  /// Hands [absolutePath] (an APK inside the app's private update directory)
  /// to the system package installer. Returns once the installer UI launched.
  Future<bool> installApk(String absolutePath);

  /// Opens the platform app-store page for this app (store flavor, which
  /// disables in-app self-update). Best-effort; a missing store handler is
  /// silently ignored.
  Future<void> openStore();
}

class AndroidPal implements PlatformPal {
  static const _storage = MethodChannel('gs/storage');
  static const _emulator = MethodChannel('gs/emulator');
  static const _updater = MethodChannel('gs/updater');
  static const _netplay = MethodChannel('gs/netplay');

  // Broadcast because the controller (and tests) may listen at different
  // times while the single AndroidPal instance lives for the app's lifetime.
  final StreamController<NetplayPlayEnd> _playEnds =
      StreamController<NetplayPlayEnd>.broadcast();

  AndroidPal() {
    _netplay.setMethodCallHandler((call) async {
      if (call.method == 'playEnded' && call.arguments is Map) {
        _playEnds.add(NetplayPlayEnd.fromMap(call.arguments as Map));
      }
      return null;
    });
  }

  @override
  Stream<NetplayPlayEnd> get netplayPlayEnds => _playEnds.stream;

  @override
  Future<void> stopNetplay() async {
    // Android native→Dart reverse callback works correctly (EmulatorActivity
    // calls notifyDartPlayEnded via the cached engine), so this is a no-op.
    // The method exists only to satisfy the PlatformPal interface.
  }

  @override
  bool get emulatorCoversFlutter => false;

  @override
  Future<String> filesDir() async {
    return await _storage.invokeMethod<String>('getFilesDir') as String;
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
      final v = await _storage.invokeMethod<int>('getAvailableBytes');
      return v;
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
    final res =
        await _storage.invokeMethod<dynamic>('importRomViaSaf', {'mime': mime});
    if (res == null) return null;
    return ImportedRom.fromMap(res as Map<dynamic, dynamic>);
  }

  @override
  Future<ImportedPackage?> importPackageViaSaf() async {
    final res = await _storage.invokeMethod<dynamic>('importPackageViaSaf');
    if (res == null) return null;
    return ImportedPackage.fromMap(res as Map<dynamic, dynamic>);
  }

  @override
  Future<String?> importBiosViaSaf() async {
    final res = await _storage.invokeMethod<dynamic>('importBiosViaSaf');
    if (res == null) return null;
    return res as String;
  }

  @override
  Future<List<String>> importBiosBatchViaSaf() async {
    final res = await _storage.invokeMethod<dynamic>('importBiosBatchViaSaf');
    if (res == null) return const <String>[];
    return (res as List).map((e) => e as String).toList();
  }

  @override
  Future<bool?> exportBiosZipViaSaf() async {
    final res = await _storage.invokeMethod<bool>('exportBiosZipViaSaf');
    return res;
  }

  @override
  Future<bool> deleteBios(String name) async {
    final ok = await _storage.invokeMethod<bool>('deleteBios', {'name': name});
    return ok ?? false;
  }

  @override
  Future<bool> exportPackageViaSaf({
    required String sourcePath,
    required String suggestedName,
  }) async {
    final ok = await _storage.invokeMethod<bool>('exportPackageViaSaf', {
      'sourcePath': sourcePath,
      'suggestedName': suggestedName,
    });
    return ok ?? false;
  }

  @override
  Future<ImportedMovesConfig?> importMovesConfigViaSaf() async {
    final res =
        await _storage.invokeMethod<dynamic>('importMovesConfigViaSaf');
    if (res == null) return null;
    return ImportedMovesConfig.fromMap(res as Map<dynamic, dynamic>);
  }

  @override
  Future<bool> exportMovesConfigViaSaf({
    required String sourcePath,
    required String suggestedName,
  }) async {
    final ok = await _storage.invokeMethod<bool>('exportMovesConfigViaSaf', {
      'sourcePath': sourcePath,
      'suggestedName': suggestedName,
    });
    return ok ?? false;
  }

  @override
  Future<ImportedPadConfig?> importPadConfigViaSaf() async {
    final res = await _storage.invokeMethod<dynamic>('importPadConfigViaSaf');
    if (res == null) return null;
    return ImportedPadConfig.fromMap(res as Map<dynamic, dynamic>);
  }

  @override
  Future<bool> exportPadConfigViaSaf({
    required String sourcePath,
    required String suggestedName,
  }) async {
    final ok = await _storage.invokeMethod<bool>('exportPadConfigViaSaf', {
      'sourcePath': sourcePath,
      'suggestedName': suggestedName,
    });
    return ok ?? false;
  }

  @override
  Future<bool> launchEmulator({
    required String relativePath,
    required String coreId,
    required String platform,
    Map<String, dynamic>? netplay,
  }) async {
    final ok = await _emulator.invokeMethod<bool>('launch', {
      'rom': relativePath,
      'core': coreId,
      'platform': platform,
      'netplay': netplay,
    });
    return ok ?? false;
  }

  @override
  Future<AppVersion> appVersion() async {
    final m = await _updater.invokeMethod<dynamic>('getVersion')
        as Map<dynamic, dynamic>;
    return AppVersion(
      versionCode: (m['versionCode'] as num).toInt(),
      versionName: m['versionName'] as String? ?? '',
    );
  }

  @override
  Future<bool> installApk(String absolutePath) async {
    final ok = await _updater
        .invokeMethod<bool>('installApk', {'path': absolutePath});
    return ok ?? false;
  }

  @override
  Future<void> openStore() async {
    await _updater.invokeMethod('openStore');
  }

  // Android persists AppSettings via shared_preferences directly, so the
  // file-store fallback is a no-op here.
  @override
  Future<Map<String, Object>?> loadAppSettings() async => null;

  @override
  Future<void> saveAppSettings(Map<String, Object> data) async {}
}
