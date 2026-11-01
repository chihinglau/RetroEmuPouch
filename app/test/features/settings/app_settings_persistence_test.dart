import 'package:flutter_test/flutter_test.dart';
import 'package:retroemupouch/features/settings/app_settings.dart';

// Covers the OHOS settings-persistence fallback: `shared_preferences` has no
// native handler on OpenHarmony, so `AppSettings` routes load()/save() through a
// PlatformPal file store (`app_prefs.json`). These tests pin the serialisation
// (`toMap`/`applyMap`) and the store contract that the fallback relies on.
void main() {
  group('AppSettings file-store fallback (OHOS)', () {
    test('toMap / applyMap round-trip every field', () {
      final s = AppSettings(
        showFpsHud: false,
        highRefreshRate: false,
        fastForwardAudio: false,
        rememberLastGame: false,
        darkTheme: false,
        stickMode: 'STICK',
        stickDeadzone: 0.31,
        useDpadUi: true,
        padScale: 1.7,
        padOffsetX: -0.2,
        padOffsetY: 0.35,
      );
      final restored = AppSettings();
      restored.applyMap(s.toMap());
      expect(restored.showFpsHud, s.showFpsHud);
      expect(restored.highRefreshRate, s.highRefreshRate);
      expect(restored.fastForwardAudio, s.fastForwardAudio);
      expect(restored.rememberLastGame, s.rememberLastGame);
      expect(restored.darkTheme, s.darkTheme);
      expect(restored.stickMode, s.stickMode);
      expect(restored.stickDeadzone, closeTo(s.stickDeadzone, 1e-9));
      expect(restored.useDpadUi, s.useDpadUi);
      expect(restored.padScale, closeTo(s.padScale, 1e-9));
      expect(restored.padOffsetX, closeTo(s.padOffsetX, 1e-9));
      expect(restored.padOffsetY, closeTo(s.padOffsetY, 1e-9));
    });

    test('applyMap tolerates missing / malformed keys (older snapshots)', () {
      final s = AppSettings();
      final before = s.clone();
      // Wrong types must be ignored, not crash.
      s.applyMap(<String, Object>{'darkTheme': 'nope', 'stickDeadzone': 'abc'});
      expect(s.darkTheme, before.darkTheme);
      expect(s.stickDeadzone, before.stickDeadzone);
      // A valid key still applies; unknown keys are dropped silently.
      s.applyMap(<String, Object>{'darkTheme': false, 'unknown': 123});
      expect(s.darkTheme, false);
    });

    test('store contract: save writes the snapshot, load reads it back', () async {
      // Mirrors OhosPal.loadAppSettings/saveAppSettings backed by app_prefs.json.
      final disk = <String, Object>{};
      Future<Map<String, Object>?> load() async =>
          disk.isEmpty ? null : Map<String, Object>.from(disk);
      Future<void> save(Map<String, Object> m) async =>
          disk..clear()..addAll(m);

      expect(await load(), isNull); // nothing persisted yet
      await save(AppSettings(darkTheme: false, stickMode: 'STICK').toMap());
      final restored = AppSettings();
      restored.applyMap((await load())!);
      expect(restored.darkTheme, false);
      expect(restored.stickMode, 'STICK');
    });

    test('AppSettings.save() routes to the fallback when prefs are absent',
        () async {
      // In a plain unit test shared_preferences has no platform handler, so
      // getInstance() throws and AppSettings must use the wired fallback store
      // — exactly the OHOS code path.
      final store = <String, Object>{};
      AppSettings.setFallbackStore(
        load: () async =>
            store.isEmpty ? null : Map<String, Object>.from(store),
        save: (m) async => store..clear()..addAll(m),
      );
      addTearDown(() => AppSettings.setFallbackStore(
            load: () async => null,
            save: (m) async {},
          ));

      await AppSettings(darkTheme: false, stickMode: 'STICK', padScale: 1.7)
          .save();
      expect(store['darkTheme'], false,
          reason: 'fallback store must receive the snapshot');

      final loaded = await AppSettings.load();
      expect(loaded.darkTheme, false);
      expect(loaded.stickMode, 'STICK');
      expect(loaded.padScale, closeTo(1.7, 1e-9));
    });

    test('clearLastSaveSlot() drops the slot via the fallback store', () async {
      // The settings sheet calls this when 「记住上次进度」 is switched off. On
      // OHOS a bare SharedPreferences.getInstance() throws, so it must fall
      // through to the file store instead of crashing the sheet.
      final store = <String, Object>{...AppSettings().toMap()};
      store['flutter.lastSaveSlot'] = 3;
      AppSettings.setFallbackStore(
        load: () async => Map<String, Object>.from(store),
        save: (m) async => store..clear()..addAll(m),
      );
      addTearDown(() => AppSettings.setFallbackStore(
            load: () async => null,
            save: (m) async {},
          ));

      await AppSettings.clearLastSaveSlot();
      expect(store.containsKey('flutter.lastSaveSlot'), isFalse);
      // Everything else must survive — we only wanted the slot gone.
      expect(store.containsKey('darkTheme'), isTrue);
      expect(store['darkTheme'], true);
    });
  });
}
