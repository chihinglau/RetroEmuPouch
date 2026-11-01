import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'data/play/multiplayer_catalog.dart';
import 'features/library/library_page.dart';
import 'features/legal/consent_gate.dart';
import 'features/settings/app_settings.dart';
import 'pal/platform_pal.dart';
import 'pal/pal_factory.dart';
import 'system_files.dart';

/// App-wide route observer. The library page (the root route) subscribes to it
/// so it can refresh disk-derived state (ROM list / saves / BIOS banner) when a
/// page pushed above it is popped — the root route never re-runs initState, so
/// without this a BIOS landed by PC 手机同步 (adb) or an in-app peer import
/// stays invisible in the "缺少系统文件" banner until a cold restart.
final RouteObserver<ModalRoute<dynamic>> appRouteObserver =
    RouteObserver<ModalRoute<dynamic>>();

/// Default `<filesDir>/settings.json` payload — the exact shape
/// GamePouchPlugin.writePadSettings() stamps for a default [AppSettings].
/// Only used by the temporary OHOS wiring self-test to restore sane values.
const Map<String, Object> _defaultSettingsJson = <String, Object>{
  'stickMode': 'DPAD8',
  'padScale': 1.0,
  'stickDeadzone': 0.18,
  'useDpadUi': false,
  'padOffsetX': 0.0,
  'padOffsetY': 0.0,
  'showFpsHud': true,
  'highRefreshRate': true,
  'fastForwardAudio': true,
};

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  // Active platform PAL (storage + emulator). Created up-front so the settings
  // fallback store can be wired before the first AppSettings.load().
  final pal = createPlatformPal();
  // On platforms without a shared_preferences native handler (OHOS), persist
  // AppSettings through the PAL file store so the settings page remembers the
  // user's choices across launches (matching Android).
  AppSettings.setFallbackStore(
    load: () => pal.loadAppSettings(),
    save: (m) => pal.saveAppSettings(m),
  );
  // Warm the settings cache before the first frame so the Settings sheet
  // can read AppSettings.current synchronously on first open.
  await AppSettings.load().then(AppSettings.cacheFrom);
  // Verify (do NOT ship) emulator BIOS files. Users must supply their own
  // legitimate copies (R1 compliance); missing BIOS are surfaced in the UI.
  try {
    await SystemFiles.checkMissing(pal);
  } catch (_) {
    // Native handlers absent (OHOS before P3): do not block startup.
  }
  // Load the offline multiplayer catalog so the peer library and the
  // signaling server fail closed (single-player) until it is available.
  try {
    await MultiplayerCatalog.loadAsset();
  } catch (_) {
    // Asset unavailable: catalog stays empty (single-player).
  }
  // R8: first-launch consent gate for privacy policy + EULA.
  // OHOS has no shared_preferences native handler yet; when prefs is
  // unavailable default to "consented" so the pure-Dart UI can boot.
  bool consented = true;
  try {
    final prefs = await SharedPreferences.getInstance();
    consented = prefs.getBool('consent_given') ?? false;
  } catch (_) {
    consented = true;
  }
  if (consented) {
    runApp(GamePouchApp());
  } else {
    runApp(ConsentGate(onAccept: () => runApp(GamePouchApp())));
  }

  // TEMP OHOS WIRING SELF-TEST: exercises every Settings-sheet backend path
  // headlessly (the OpenHarmony `uitest` driver cannot reach Flutter widgets),
  // then writes a report to `<filesDir>/selftest.txt` so it can be pulled with
  // `hdc shell -b com.retroemupouch.app cat <filesDir>/selftest.txt`.
  // Enable with `--dart-define=GP_OHOS_SELFTEST=true` to re-run the on-device
  // audit; it mutates AppSettings and launches roms/yx.nes, then restores the
  // defaults before exiting.
  const bool kOhosWiringSelfTest =
      bool.fromEnvironment('GP_OHOS_SELFTEST');
  // Launch target of the probe, overridable per run:
  //   --dart-define=GP_PROBE_ROM=roms/peer/ffight.zip
  //   --dart-define=GP_PROBE_CORE=mame  --dart-define=GP_PROBE_PLATFORM=mame
  const String kProbeRom =
      String.fromEnvironment('GP_PROBE_ROM', defaultValue: 'roms/yx.nes');
  const String kProbeCore =
      String.fromEnvironment('GP_PROBE_CORE', defaultValue: 'fceumm');
  const String kProbePlatform =
      String.fromEnvironment('GP_PROBE_PLATFORM', defaultValue: 'nes');
  // When GP_PROBE_NETPLAY=true the OHOS self-test launches the emulator as a
  // netplay GUEST headlessly (no UI / no manual tap) so a cross-device
  // checkpoint comparison can run unattended. The host is an Android device
  // started via `am start` with np_* intent extras (see docs/skills.md §11).
  const bool kProbeNetplay = bool.fromEnvironment('GP_PROBE_NETPLAY');
  const String kProbePeerIp =
      String.fromEnvironment('GP_PROBE_PEER_IP', defaultValue: '192.168.0.5');
  const String kProbeKey = String.fromEnvironment(
      'GP_PROBE_KEY',
      defaultValue: '00112233445566778899aabbccddeeff00112233445566778899aabbccddeeff');
  const int kProbeRoom = int.fromEnvironment('GP_PROBE_ROOM', defaultValue: 123456);
  const int kProbeAndroidUdp =
      int.fromEnvironment('GP_PROBE_ANDROID_UDP', defaultValue: 19840);
  const int kProbeAndroidBoot =
      int.fromEnvironment('GP_PROBE_ANDROID_BOOT', defaultValue: 19841);
  const int kProbeOhosUdp =
      int.fromEnvironment('GP_PROBE_OHOS_UDP', defaultValue: 19842);
  // Bootstrap TCP port the OHOS device listens on when it is the host (the
  // Android host uses kProbeAndroidBoot).
  const int kProbeOhosBoot =
      int.fromEnvironment('GP_PROBE_OHOS_BOOT', defaultValue: 19843);
  // 0 = host, 1 = guest (default guest, the original probe behaviour).
  const int kProbeRole = int.fromEnvironment('GP_PROBE_ROLE', defaultValue: 1);
  if (kOhosWiringSelfTest && !kProbeNetplay) {
    Future<void>.delayed(const Duration(seconds: 2), () async {
      final lines = <String>[];
      void log(String s) {
        lines.add(s);
        // ignore: avoid_print
        print('[selftest] $s');
      }

      try {
        final dir = await pal.filesDir();
        log('filesDir=$dir');
        log('deviceModel=${await pal.deviceModel()}');
        log('availableBytes=${await pal.availableBytes()}');
        log('runningSaveKey(before)=${await pal.runningSaveKey()}');
        log('appVersion=${(await pal.appVersion()).versionName}');
        // Proves the snapshot survives a cold restart (the previous run's
        // values must be here, not the class defaults).
        log('settings.atBoot=${AppSettings.current.toMap()}');

        // 1) AppSettings must survive a save/load round-trip through the PAL
        //    file store (shared_preferences has no OHOS handler). The settings
        //    sheet mutates `AppSettings.current` in place (see
        //    _SettingsSheetState._patch), so mirror that here.
        final mutated = AppSettings.current;
        mutated
          ..showFpsHud = false
          ..highRefreshRate = false
          ..fastForwardAudio = false
          ..stickMode = 'DPAD4'
          ..stickDeadzone = 0.31
          ..useDpadUi = true
          ..padScale = 1.75
          ..padOffsetX = -0.2
          ..padOffsetY = 0.15;
        await mutated.save();
        final reread = await AppSettings.load();
        log('settings.roundtrip='
            'fps=${reread.showFpsHud},hrr=${reread.highRefreshRate},'
            'ffa=${reread.fastForwardAudio},stick=${reread.stickMode},'
            'dz=${reread.stickDeadzone},dpadUi=${reread.useDpadUi},'
            'scale=${reread.padScale},ox=${reread.padOffsetX},oy=${reread.padOffsetY}');
        log('settings.roundtrip.ok='
            '${reread.showFpsHud == false && reread.stickMode == 'DPAD4' && reread.padScale == 1.75 && reread.padOffsetX == -0.2 && reread.padOffsetY == 0.15 && reread.useDpadUi}');
        final prefsFile = File('$dir/app_prefs.json');
        log('app_prefs.json.exists=${prefsFile.existsSync()}');

        // 2) 「记住上次进度」 side effect must not throw and must clear the slot.
        await AppSettings.clearLastSaveSlot();
        log('clearLastSaveSlot.ok=true');

        // 3) 招式按键: write the same shape SpecialMovesEditor produces and
        //    check EmulatorSpike's loadMoves() picks it up (see hilog
        //    `[EmulatorSpike] loadMoves ...`).
        final movesDir = Directory('$dir/library')..createSync(recursive: true);
        File('${movesDir.path}/moves.json').writeAsStringSync(
            '{"version":1,"activeProfileId":"selftest","profiles":'
            '{"selftest":{"label":"SELFTEST","moves":'
            '[{"label":"SELFTEST-A","script":"236+P"}]}}}');
        log('moves.json written');

        // 4) Launching the emulator must stamp the pad + prefs config into
        //    `<filesDir>/settings.json` (what EmulatorSpike.loadSettings reads).
        log('settings.current=${AppSettings.current.toMap()}');
        final romRel = kProbeRom;
        log('probe.rom=$romRel core=$kProbeCore platform=$kProbePlatform');
        log('rom.exists=${File('$dir/$romRel').existsSync()} '
            'size=${File('$dir/$romRel').existsSync() ? File('$dir/$romRel').lengthSync() : 0}');
        final launched = await pal.launchEmulator(
          relativePath: romRel,
          coreId: kProbeCore,
          platform: kProbePlatform,
        );
        log('launch.ok=$launched');
        await Future<void>.delayed(const Duration(milliseconds: 1500));
        final sj = File('$dir/settings.json');
        log('settings.json=${sj.existsSync() ? sj.readAsStringSync() : '<missing>'}');
        log('runningSaveKey(after)=${await pal.runningSaveKey()}');

        // 5) Restore the defaults this test clobbered, so the next normal
        //    launch starts from a sane pad layout instead of scale 1.75 / -0.2.
        AppSettings.cacheFrom(AppSettings());
        await AppSettings.current.save();
        sj.writeAsStringSync(jsonEncode(_defaultSettingsJson));
        log('restored.settings.json=${sj.readAsStringSync()}');
        log('restored.app_prefs=${File('$dir/app_prefs.json').readAsStringSync()}');
        // Drop the synthetic moves profile so the emulator falls back to the
        // built-in presets again (never delete a real user profile).
        final mj = File('${movesDir.path}/moves.json');
        if (mj.existsSync() && mj.readAsStringSync().contains('SELFTEST')) {
          mj.deleteSync();
          log('moves.json removed (test profile)');
        }
      } catch (e, st) {
        log('EXCEPTION=$e');
        log('STACK=$st');
      }

      try {
        final dir = await pal.filesDir();
        File('$dir/selftest.txt').writeAsStringSync('${lines.join('\n')}\n');
      } catch (_) {
        // best effort
      }
    });
  }

  // Headless netplay GUEST probe: launch kof97/mame as a netplay guest against
  // an Android host started via `am start` with np_* intent extras — no UI, no
  // manual tap. Drives the automated cross-device determinism comparison.
  if (kProbeNetplay) {
    Future<void>.delayed(const Duration(seconds: 2), () async {
      final lines = <String>[];
      void log(String s) {
        lines.add(s);
        // ignore: avoid_print
        print('[netprobe] $s');
      }
      try {
        final dir = await pal.filesDir();
        // The host IP is DHCP-assigned and moves between runs; rebuilding the
        // HAP just to bump a dart-define is far too slow. Allow a runtime
        // override: if `<filesDir>/netprobe.txt` (the file this probe also uses
        // for its report) starts with a bare IPv4 literal — staged with
        // `hdc -b <pkg> "cat > .../files/netprobe.txt"` — use it as the peer.
        var peerIp = kProbePeerIp;
        final cfg = File('$dir/netprobe.txt');
        if (cfg.existsSync()) {
          for (final l in cfg.readAsStringSync().split('\n')) {
            final t = l.trim();
            if (RegExp(r'^\d{1,3}(\.\d{1,3}){3}$').hasMatch(t)) {
              peerIp = t;
              break;
            }
          }
        }
        // GP_PROBE_ROLE lets the SAME probe run either side of the pair: the
        // OHOS device must be verifiable as host too (that is the direction the
        // UI uses when the invite is created on this phone).
        final host = kProbeRole == 0;
        final netplay = <String, dynamic>{
          'role': kProbeRole,
          'peerIp': peerIp,
          'peerPort': host ? kProbeAndroidUdp : kProbeAndroidUdp,
          'localPort': kProbeOhosUdp,
          'sessionKey': kProbeKey,
          'roomId': kProbeRoom,
          'initialD': 2,
          'adaptive': true,
          'bootstrapPort': host ? kProbeOhosBoot : kProbeAndroidBoot,
          'saveKey': '24D7C9E0',
          'coreId': 'mame',
        };
        log('probe.netplay role=${host ? 'host' : 'guest'} peer=$peerIp '
            '(define=$kProbePeerIp) boot=${netplay['bootstrapPort']} '
            'keyLen=${kProbeKey.length} room=$kProbeRoom');
        final launched = await pal.launchEmulator(
          relativePath: kProbeRom,
          coreId: kProbeCore,
          platform: kProbePlatform,
          netplay: netplay,
        );
        log('launch.ok=$launched');
      } catch (e, st) {
        log('EXCEPTION=$e');
        log('STACK=$st');
      }
      try {
        final dir = await pal.filesDir();
        File('$dir/netprobe.txt').writeAsStringSync('${lines.join('\n')}\n');
      } catch (_) {
        // best effort
      }
    });
  }
}

class GamePouchApp extends StatefulWidget {
  GamePouchApp({super.key});

  // P2: select ohos/ios PAL behind the same interface via the platform factory.
  final PlatformPal pal = createPlatformPal();

  /// Lookup hook so descendants (e.g. the Settings sheet) can find the
  /// [GamePouchApp] state and ask it to flip the brightness without
  /// having to re-inject a custom InheritedWidget.
  static GamePouchAppState? of(BuildContext context) =>
      context.findAncestorStateOfType<GamePouchAppState>();

  @override
  State<GamePouchApp> createState() => GamePouchAppState();
}

class GamePouchAppState extends State<GamePouchApp> {
  /// Brightness keyed off the current persisted setting. Toggled at
  /// runtime via [setBrightness] when the user changes the setting
  /// inside the app, so the theme updates without an app restart.
  late Brightness _brightness;

  @override
  void initState() {
    super.initState();
    _brightness =
        AppSettings.current.darkTheme ? Brightness.dark : Brightness.light;
  }

  /// Switch the running app between dark and light themes.
  void setBrightness(bool dark) {
    if (!mounted) return;
    setState(() {
      _brightness = dark ? Brightness.dark : Brightness.light;
    });
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: '趣玩匣',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        useMaterial3: true,
        brightness: _brightness,
        colorSchemeSeed: const Color(0xFF4FC3F7),
        visualDensity: VisualDensity.standard,
      ),
      home: LibraryPage(pal: widget.pal),
      navigatorObservers: [appRouteObserver],
    );
  }
}
