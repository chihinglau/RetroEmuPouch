import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

/// App-level preferences that persist across launches via shared_preferences.
///
/// Kept tiny on purpose: only the user-visible toggles from the Settings
/// sheet live here. Each preference has a single source of truth (this
/// class); UI code reads/writes through [AppSettings.load] and
/// [AppSettings.save].
class AppSettings {
  AppSettings({
    this.showFpsHud = true,
    this.highRefreshRate = true,
    this.fastForwardAudio = true,
    this.rememberLastGame = true,
    this.darkTheme = true,
    this.stickMode = 'DPAD8',
    this.stickDeadzone = 0.18,
    this.useDpadUi = false,
    this.padScale = 1.0,
    this.padOffsetX = 0.0,
    this.padOffsetY = 0.0,
  });

  /// Returns an independent copy of this settings record — used by the
  /// settings sheet to detect what changed since the user opened it so
  /// the right side effects (e.g. clearing `lastSaveSlot`) only fire
  /// for transitions, not for every save.
  AppSettings clone() => AppSettings(
        showFpsHud: showFpsHud,
        highRefreshRate: highRefreshRate,
        fastForwardAudio: fastForwardAudio,
        rememberLastGame: rememberLastGame,
        darkTheme: darkTheme,
        stickMode: stickMode,
        stickDeadzone: stickDeadzone,
        useDpadUi: useDpadUi,
        padScale: padScale,
        padOffsetX: padOffsetX,
        padOffsetY: padOffsetY,
      );

  /// Show the FPS / xruns overlay in the corner of the picture.
  bool showFpsHud;

  /// Ask Android for a high refresh rate (60 / 90 / 120 Hz) on supported
  /// panels — keeps scroll judder down on high-refresh OLED phones.
  bool highRefreshRate;

  /// Sync in-game audio when the user enables fast-forward (加速×N).
  /// When off, audio is muted at >×1 to keep emulation stable.
  bool fastForwardAudio;

  /// Auto-resume the last played ROM on app launch.
  bool rememberLastGame;

  /// Use the dark Material theme everywhere (default for OLED comfort).
  bool darkTheme;

  /// Direction-input style. One of 'STICK' (analog), 'DPAD8' (8-way snap),
  /// 'DPAD4' (4-way snap). Mirrored into Kotlin via FlutterSharedPreferences.
  /// String-valued so future modes can be added without bumping a schema.
  String stickMode;

  /// Dead-zone fraction (0.0–0.45) — fraction of the knob's max travel below
  /// which the stick reads as centred. 0.18 is the default compromise: light
  /// flicks register, but centre jitter doesn't.
  ///
  /// Persisted as a plain text String (NOT `shared_preferences.setDouble`).
  /// `setDouble` base64-encodes its payload, which raises
  /// `ClassCastException: String cannot be cast to Float` when the native
  /// Kotlin side calls `SharedPreferences.getFloat` — that bug previously
  /// crashed every emulator launch. See [_decodeDeadzone] for the legacy
  /// base64 fallback that lets existing on-disk values load.
  double stickDeadzone;

  /// When true, the analog stick is replaced with a 4-button virtual d-pad
  /// (↑/↓/←/→). Better for action / platformer titles that don't understand
  /// diagonal input.
  bool useDpadUi;

  /// 虚拟手柄整体缩放(以默认大小为基准)。1.0 = 默认; 0.5–2.5 允许用户按屏幕大小放大/缩小。
  double padScale;

  /// 虚拟手柄整体水平平移(相对屏幕宽度的比例, 负=左, 正=右)。与 [padOffsetY] 一起,
  /// 让左手摇杆/十字键与右手 ABXY 整组移动, 适配不同握持习惯。
  double padOffsetX;

  /// 虚拟手柄整体垂直平移(相对屏幕高度的比例, 负=上, 正=下)。
  double padOffsetY;

  static final AppSettings _cached = AppSettings();

  /// Reads the current settings from disk. Falls back to defaults if no
  /// settings file exists yet (e.g. first launch after install).
  static Future<AppSettings> load() async {
    final s = AppSettings();
    try {
      final p = await SharedPreferences.getInstance();
      s.showFpsHud = p.getBool(_kShowFpsHud) ?? s.showFpsHud;
      s.highRefreshRate = p.getBool(_kHighRefreshRate) ?? s.highRefreshRate;
      s.fastForwardAudio = p.getBool(_kFastForwardAudio) ?? s.fastForwardAudio;
      s.rememberLastGame = p.getBool(_kRememberLastGame) ?? s.rememberLastGame;
      s.darkTheme = p.getBool(_kDarkTheme) ?? s.darkTheme;
      s.stickMode = p.getString(_kStickMode) ?? s.stickMode;
      s.stickDeadzone =
          _decodeDeadzone(p.getString(_kStickDeadzone)) ?? s.stickDeadzone;
      s.useDpadUi = p.getBool(_kUseDpadUi) ?? s.useDpadUi;
      s.padScale = _decodeFloat(p.getString(_kPadScale)) ?? s.padScale;
      s.padOffsetX = _decodeFloat(p.getString(_kPadOffsetX)) ?? s.padOffsetX;
      s.padOffsetY = _decodeFloat(p.getString(_kPadOffsetY)) ?? s.padOffsetY;
      return s;
    } catch (_) {
      // Native shared_preferences handler is absent (e.g. OHOS). Fall back to
      // the PlatformPal file store so settings persist across launches.
    }
    try {
      final fb = await _fallbackLoad?.call();
      if (fb != null) s.applyMap(fb);
    } catch (_) {
      // No fallback store either: defaults stand.
    }
    return s;
  }

  /// Persists the current settings to disk. Safe to call from any
  /// isolate — SharedPreferences serialises the writes internally.
  Future<void> save() async {
    try {
      final p = await SharedPreferences.getInstance();
      await p.setBool(_kShowFpsHud, showFpsHud);
      await p.setBool(_kHighRefreshRate, highRefreshRate);
      await p.setBool(_kFastForwardAudio, fastForwardAudio);
      await p.setBool(_kRememberLastGame, rememberLastGame);
      await p.setBool(_kDarkTheme, darkTheme);
      await p.setString(_kStickMode, stickMode);
      await p.setString(_kStickDeadzone, stickDeadzone.toString());
      await p.setBool(_kUseDpadUi, useDpadUi);
      await p.setString(_kPadScale, padScale.toString());
      await p.setString(_kPadOffsetX, padOffsetX.toString());
      await p.setString(_kPadOffsetY, padOffsetY.toString());
      return;
    } catch (_) {
      // shared_preferences unavailable (e.g. OHOS): persist via the PAL store.
    }
    try {
      await _fallbackSave?.call(toMap());
    } catch (_) {
      // No fallback store either: settings stay in memory this session.
    }
  }

  /// Clears the "last save slot" pointer so the next emulator entry won't
  /// auto-load the previous game. Called when 「记住上次进度」 is switched off.
  ///
  /// Goes through the same shared_preferences-then-file-store ladder as
  /// [save] — a bare `SharedPreferences.getInstance()` throws on OHOS (no
  /// native handler), which would leave the stale slot behind *and* surface an
  /// unhandled async error in the settings sheet.
  static Future<void> clearLastSaveSlot() async {
    var handled = false;
    try {
      final p = await SharedPreferences.getInstance();
      handled = await p.remove(_kLastSaveSlot);
    } catch (_) {
      // shared_preferences unavailable (e.g. OHOS): use the file store below.
    }
    if (handled) return;
    try {
      final current = await _fallbackLoad?.call();
      if (current == null) return;
      final next = Map<String, Object>.of(current)..remove(_kLastSaveSlot);
      await _fallbackSave?.call(next);
    } catch (_) {
      // No fallback store either: nothing persisted to clear.
    }
  }

  // ---- PlatformPal file-store fallback (shared_preferences-less platforms) ----
  // Wired by main() from the active PlatformPal so settings persist on OHOS,
  // where shared_preferences has no native handler.
  static Future<Map<String, Object>?> Function()? _fallbackLoad;
  static Future<void> Function(Map<String, Object>)? _fallbackSave;

  static void setFallbackStore({
    required Future<Map<String, Object>?> Function() load,
    required Future<void> Function(Map<String, Object>) save,
  }) {
    _fallbackLoad = load;
    _fallbackSave = save;
  }

  /// Serialises the settings to a string-keyed map (doubles as text, mirroring
  /// how shared_preferences stores them) for the file-store fallback.
  Map<String, Object> toMap() => {
        _kShowFpsHud: showFpsHud,
        _kHighRefreshRate: highRefreshRate,
        _kFastForwardAudio: fastForwardAudio,
        _kRememberLastGame: rememberLastGame,
        _kDarkTheme: darkTheme,
        _kStickMode: stickMode,
        _kStickDeadzone: stickDeadzone.toString(),
        _kUseDpadUi: useDpadUi,
        _kPadScale: padScale.toString(),
        _kPadOffsetX: padOffsetX.toString(),
        _kPadOffsetY: padOffsetY.toString(),
      };

  /// Applies a persisted map (see [toMap]); unknown/malformed keys are ignored
  /// so an older snapshot never breaks a newer build.
  void applyMap(Map<String, Object> m) {
    final b0 = m[_kShowFpsHud]; if (b0 is bool) showFpsHud = b0;
    final b1 = m[_kHighRefreshRate]; if (b1 is bool) highRefreshRate = b1;
    final b2 = m[_kFastForwardAudio]; if (b2 is bool) fastForwardAudio = b2;
    final b3 = m[_kRememberLastGame]; if (b3 is bool) rememberLastGame = b3;
    final b4 = m[_kDarkTheme]; if (b4 is bool) darkTheme = b4;
    final sm = m[_kStickMode]; if (sm is String) stickMode = sm;
    final sd = m[_kStickDeadzone];
    if (sd is String) stickDeadzone = _decodeDeadzone(sd) ?? stickDeadzone;
    final du = m[_kUseDpadUi]; if (du is bool) useDpadUi = du;
    final ps = m[_kPadScale]; if (ps is String) padScale = _decodeFloat(ps) ?? padScale;
    final px = m[_kPadOffsetX]; if (px is String) padOffsetX = _decodeFloat(px) ?? padOffsetX;
    final py = m[_kPadOffsetY]; if (py is String) padOffsetY = _decodeFloat(py) ?? padOffsetY;
  }

  /// Decode the stickDeadzone preference, tolerating both the current
  /// clean-text format ("0.18") and the legacy base64-wrapped Double that
  /// earlier builds wrote via `shared_preferences.setDouble` (whose XML
  /// value is base64("This is the prefix for Double." + 8 binary bytes)).
  /// Returns null if neither format yields a valid double.
  static double? _decodeDeadzone(String? raw) {
    if (raw == null) return null;
    // Clean text format.
    final d = double.tryParse(raw);
    if (d != null) return d.clamp(0.0, 0.45);
    // Legacy base64 format from setDouble().
    try {
      final bytes = base64.decode(raw);
      final text = utf8.decode(bytes);
      const prefix = 'This is the prefix for Double.';
      if (text.startsWith(prefix)) {
        return double.tryParse(text.substring(prefix.length))?.clamp(0.0, 0.45);
      }
    } catch (_) {/* fall through */}
    return null;
  }

  /// Synchronous view of the in-memory cached settings. Always returns a
  /// non-null value — falls back to defaults if [load] hasn't completed
  /// yet. Callers that need the persisted value at app startup should
  /// `await AppSettings.load()` first.
  static AppSettings get current => _cached;

  /// Copies every field of [s] into the cached instance, so the synchronous
  /// [current] view matches what [load] just read from disk.
  ///
  /// `main()` uses this to warm the cache before the first frame. It must copy
  /// **all** fields — an earlier version copied only the five booleans the
  /// theme/FPS paths needed, so `stickMode` / `stickDeadzone` / `useDpadUi` /
  /// `padScale` / `padOffsetX` / `padOffsetY` stayed at their defaults and the
  /// Settings sheet's pad layout never reached the native emulator surface.
  static void cacheFrom(AppSettings s) {
    _cached
      ..showFpsHud = s.showFpsHud
      ..highRefreshRate = s.highRefreshRate
      ..fastForwardAudio = s.fastForwardAudio
      ..rememberLastGame = s.rememberLastGame
      ..darkTheme = s.darkTheme
      ..stickMode = s.stickMode
      ..stickDeadzone = s.stickDeadzone
      ..useDpadUi = s.useDpadUi
      ..padScale = s.padScale
      ..padOffsetX = s.padOffsetX
      ..padOffsetY = s.padOffsetY;
  }

  /// Decode a float preference stored as plain text (mirrors [_decodeDeadzone]
  /// for the stick-deadzone key). Returns null if the raw value isn't a valid
  /// number so the caller can fall back to the default.
  static double? _decodeFloat(String? raw) {
    if (raw == null) return null;
    return double.tryParse(raw)?.clamp(-0.45, 2.5);
  }

  static const _kShowFpsHud = 'showFpsHud';
  static const _kHighRefreshRate = 'highRefreshRate';
  static const _kFastForwardAudio = 'fastForwardAudio';
  static const _kRememberLastGame = 'rememberLastGame';
  static const _kDarkTheme = 'darkTheme';
  static const _kStickMode = 'stickMode';
  static const _kStickDeadzone = 'stickDeadzone';
  static const _kUseDpadUi = 'useDpadUi';
  static const _kPadScale = 'padScale';
  static const _kPadOffsetX = 'padOffsetX';
  static const _kPadOffsetY = 'padOffsetY';

  /// Written by the native emulator (Android `EmulatorActivity`) with the
  /// `flutter.` prefix shared_preferences applies; lives in the same store as
  /// the keys above so a single ladder can clear it.
  static const _kLastSaveSlot = 'flutter.lastSaveSlot';
}
