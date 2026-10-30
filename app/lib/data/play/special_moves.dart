import 'dart:convert';
import 'dart:io';

/// Direction encoding for the macro script syntax. Keys match the standard
/// numpad layout (1=down-left, 2=down, ..., 6=right, ..., 9=up-right),
/// mirroring what fighting-game communities use for "numpad notation":
///   7=↖  8=↑  9=↗
///   4=←  5=中 6=→
///   1=↙  2=↓  3=↘
enum _Dir { dl, dn, dr, lf, mid, rt, ul, up, ur }

const _dirChars = {
  '1': _Dir.dl,
  '2': _Dir.dn,
  '3': _Dir.dr,
  '4': _Dir.lf,
  '5': _Dir.mid,
  '6': _Dir.rt,
  '7': _Dir.ul,
  '8': _Dir.up,
  '9': _Dir.ur,
};

// VirtualPadView constants: UP=1<<4, DOWN=1<<5, LEFT=1<<6, RIGHT=1<<7.
// Numpad script → cardinal / diagonal mask. `5` is neutral (empty frame).
const _dirMasks = <_Dir, int>{
  _Dir.dl: (1 << 5) | (1 << 6), // ↙  Dn|Lf
  _Dir.dn: 1 << 5,              // ↓  Dn
  _Dir.dr: (1 << 5) | (1 << 7), // ↘  Dn|Rt
  _Dir.lf: 1 << 6,              // ←  Lf
  _Dir.mid: 0,                  // ·  neutral
  _Dir.ul: (1 << 4) | (1 << 6), // ↖  Up|Lf
  _Dir.up: 1 << 4,              // ↑  Up
  _Dir.ur: (1 << 4) | (1 << 7), // ↗  Up|Rt
  _Dir.rt: 1 << 7,              // →  Rt
};

/// Button tokens inside the script (case-insensitive).
/// `P` = light punch (NeoGeo A → retropad B = 1<<0),
/// `H` = heavy punch (NeoGeo C → retropad Y = 1<<1),
/// `L` = light kick  (NeoGeo B → retropad A = 1<<8),
/// `K` = heavy kick  (NeoGeo D → retropad X = 1<<9).
const _buttonTokens = <String, int>{
  'P': 1 << 0,
  'H': 1 << 1,
  'L': 1 << 8,
  'K': 1 << 9,
};

/// Compiles a user-authored script into the per-frame retropad mask
/// sequence that `nativePlayMacro` already consumes.
///
/// Script grammar (whitespace ignored):
///   script     := segments
///   segments   := segment (',' segment)* ('+' buttons)?
///   segment    := digit+           // numpad digits, e.g. "236"
///   buttons    := button ('+' button)*
///   button     := 'P' | 'H' | 'L' | 'K'
///
/// Each digit in a segment is held for [framesPerStep] frames (the same
/// 3-frame cadence as `two()` in VirtualPadView.kt — a digital d-pad
/// needs ~50 ms per direction for the core's motion buffer to latch it).
/// When [buttons] is non-empty the last frame of the last segment also
/// holds the button mask for an additional [framesPerStep] frames so the
/// attack registers cleanly after the motion completes.
class ScriptCompiler {
  static const framesPerStep = 3;

  /// Returns the per-frame masks. Throws [FormatException] on bad input —
  /// callers should funnel user input through [validateScript] first.
  static List<int> compile(String script) {
    final s = script.replaceAll(RegExp(r'\s+'), '');
    if (s.isEmpty) return const <int>[];
    final parts = s.split('+');
    if (parts.isEmpty) return const <int>[];
    // `+` is the only separator between motion chunks and the trailing
    // button group; when no `+` is present the *entire* script is motion
    // and there is no button group to peel off. (Splitting on `+` and
    // unconditionally treating the last chunk as buttons would route
    // pure-direction scripts like "236" or "5" into the button parser
    // and fail with "未知的按键".)
    final hasButton = parts.length > 1;
    final tail = hasButton ? parts.removeLast() : '';
    final segments = parts;
    final masks = <int>[];
    for (var i = 0; i < segments.length; i++) {
      final seg = segments[i];
      for (var j = 0; j < seg.length; j++) {
        final d = _dirChars[seg[j]];
        if (d == null) {
          throw FormatException(
              '未知的方向字符 "${seg[j]}" — 仅支持数字 1-9（小键盘方向）');
        }
        final m = _dirMasks[d]!;
        for (var k = 0; k < framesPerStep; k++) {
          masks.add(m);
        }
      }
    }
    // Trailing button group: each button is held for framesPerStep frames,
    // applied on top of the last emitted motion frame so the combo stays
    // legal in the game's motion buffer. If there were no segments, the
    // buttons simply emit a clean hold.
    if (tail.isNotEmpty) {
      final tailMasks = <int>[];
      for (var i = 0; i < tail.length; i++) {
        final ch = tail[i].toUpperCase();
        final b = _buttonTokens[ch];
        if (b == null) {
          throw FormatException(
              '未知的按键 "${tail[i]}" — 仅支持 P/H/L/K（轻拳/重拳/轻踢/重踢）');
        }
        for (var k = 0; k < framesPerStep; k++) {
          tailMasks.add(b);
        }
      }
      // The last motion frame becomes the base so attack-on-motion stays valid.
      final base = masks.isEmpty ? 0 : masks.last;
      for (var k = 0; k < tailMasks.length; k++) {
        masks.add(base | tailMasks[k]);
      }
    }
    return masks;
  }

  /// Returns null on success, or a human-readable error message.
  static String? validate(String script) {
    try {
      compile(script);
      return null;
    } on FormatException catch (e) {
      return e.message;
    } on Exception catch (e) {
      return e.toString();
    }
  }
}

/// A single macro slot: a label and the per-frame mask sequence that the
/// view hands to the native runner when the slot is tapped.
class SpecialMove {
  SpecialMove({required this.label, required this.script});

  /// Short label drawn on the pill (1 char ideally — KOF uses 单字: 波/升/旋).
  final String label;

  /// The user-authored script (e.g. "236+P"). Persisted as-is so a future
  /// edit round-trips without lossy conversion.
  final String script;

  /// Lazy-compiled per-frame masks. Throws on bad script; call
  /// [validateScript] at the editor boundary first.
  List<int> compileSeq() => ScriptCompiler.compile(script);

  Map<String, dynamic> toJson() =>
      <String, dynamic>{'label': label, 'script': script};

  factory SpecialMove.fromJson(Map<String, dynamic> m) => SpecialMove(
        label: (m['label'] as String?) ?? '',
        script: (m['script'] as String?) ?? '',
      );

  SpecialMove copyWith({String? label, String? script}) =>
      SpecialMove(label: label ?? this.label, script: script ?? this.script);
}

/// A preset profile — e.g. one for KOF97, one for KOF98, one for user
/// experiments. The active profile is what the view renders.
class SpecialMoveProfile {
  SpecialMoveProfile({
    required this.id,
    required this.label,
    required this.gameHints,
    required this.moves,
  });

  final String id;
  final String label;

  /// Free-form strings used by future per-game auto-pickers (e.g. "kof97",
  /// "neogeo", ROM CRC). Not consulted today; kept in the schema so a
  /// future 「按游戏自动选择预设」 can wire up without a breaking change.
  final List<String> gameHints;

  /// Exactly 6 slots in the current UI; we accept any length on the model
  /// side so a non-6 layout can land without a schema bump.
  final List<SpecialMove> moves;

  Map<String, dynamic> toJson() => <String, dynamic>{
        'label': label,
        'gameHints': gameHints,
        'moves': moves.map((m) => m.toJson()).toList(),
      };

  factory SpecialMoveProfile.fromJson(String id, Map<String, dynamic> m) =>
      SpecialMoveProfile(
        id: id,
        label: (m['label'] as String?) ?? id,
        gameHints: ((m['gameHints'] as List?) ?? const [])
            .map((e) => e.toString())
            .toList(),
        moves: ((m['moves'] as List?) ?? const [])
            .map((e) => SpecialMove.fromJson(
                (e as Map).cast<String, dynamic>()))
            .toList(),
      );

  SpecialMoveProfile copyWith({
    String? label,
    List<String>? gameHints,
    List<SpecialMove>? moves,
  }) =>
      SpecialMoveProfile(
        id: id,
        label: label ?? this.label,
        gameHints: gameHints ?? this.gameHints,
        moves: moves ?? this.moves,
      );
}

/// Top-level configuration: version, active profile id, and a map of
/// every preset the user can switch between (including ones imported).
class SpecialMovesConfig {
  SpecialMovesConfig({
    this.version = 1,
    required this.activeProfileId,
    required this.profiles,
  });

  final int version;
  final String activeProfileId;
  final Map<String, SpecialMoveProfile> profiles;

  SpecialMoveProfile activeProfile() {
    final p = profiles[activeProfileId] ?? profiles.values.first;
    return p;
  }

  Map<String, dynamic> toJson() => <String, dynamic>{
        'version': version,
        'activeProfileId': activeProfileId,
        'profiles': profiles.map((k, v) => MapEntry(k, v.toJson())),
      };

  String toJsonString() => const JsonEncoder.withIndent('  ').convert(toJson());

  factory SpecialMovesConfig.fromJson(Map<String, dynamic> m) {
    final raw = (m['profiles'] as Map?) ?? const {};
    final profiles = <String, SpecialMoveProfile>{};
    raw.forEach((k, v) {
      profiles[k.toString()] =
          SpecialMoveProfile.fromJson(k.toString(), (v as Map).cast<String, dynamic>());
    });
    final fallback = profiles.isEmpty
        ? ''
        : (m['activeProfileId'] as String?) ?? profiles.keys.first;
    return SpecialMovesConfig(
      version: (m['version'] as int?) ?? 1,
      activeProfileId: fallback,
      profiles: profiles,
    );
  }

  factory SpecialMovesConfig.fromJsonString(String s) =>
      SpecialMovesConfig.fromJson((jsonDecode(s) as Map).cast<String, dynamic>());

  /// Returns a copy with [activeProfileId] swapped and (optionally) a
  /// different profile list.
  SpecialMovesConfig copyWith({
    String? activeProfileId,
    Map<String, SpecialMoveProfile>? profiles,
  }) =>
      SpecialMovesConfig(
        version: version,
        activeProfileId: activeProfileId ?? this.activeProfileId,
        profiles: profiles ?? this.profiles,
      );
}

/// Loads / saves / parses the on-disk `library/moves.json` file.
///
/// Mirrors the `CheatStore` + `RomLibrary` pattern: atomic write via
/// `.tmp` + `rename`, fail-soft read (missing / corrupt → caller decides
/// between bundling a default and erroring out).
class SpecialMovesFile {
  static const String dirName = 'library';
  static const String fileName = 'moves.json';

  static File file(String filesDir) =>
      File('$filesDir/$dirName/$fileName');

  /// Reads the config from disk. Returns null when the file is missing or
  /// unreadable / malformed — the caller should fall back to a default
  /// asset in that case (see [assetsDefaultJson]).
  static SpecialMovesConfig? tryLoad(String filesDir) {
    try {
      final f = file(filesDir);
      if (!f.existsSync()) return null;
      final s = f.readAsStringSync();
      if (s.trim().isEmpty) return null;
      return SpecialMovesConfig.fromJsonString(s);
    } catch (_) {
      return null;
    }
  }

  /// Atomic write: write to a sibling .tmp, rename into place so a crash
  /// mid-write never leaves a half-baked moves.json behind.
  static void save(String filesDir, SpecialMovesConfig cfg) {
    final dir = Directory('$filesDir/$dirName')..createSync(recursive: true);
    final f = File('${dir.path}/$fileName');
    final tmp = File('${f.path}.tmp');
    tmp.writeAsStringSync(cfg.toJsonString());
    tmp.renameSync(f.path);
  }
}

/// The bundled default JSON shipped inside the APK. Loaded by
/// `SpecialMovesStore.loadDefaults` on the native side; the Dart side
/// uses [SpecialMovesFile.tryLoad] and falls back to this when the
/// on-disk file is missing so the editor can still show something useful
/// even if a user nuked the config.
///
/// We intentionally keep this string identical in shape to the Kotlin
/// parser's expected schema; both sides must agree on the field names.
const String assetsDefaultMovesJson = r'''
{
  "version": 1,
  "activeProfileId": "kof97",
  "profiles": {
    "kof97": {
      "label": "KOF97（默认）",
      "gameHints": ["kof97", "neogeo"],
      "moves": [
        { "label": "波", "script": "236+P" },
        { "label": "升", "script": "623+P" },
        { "label": "旋", "script": "214+K" },
        { "label": "超", "script": "236236+PK" },
        { "label": "避", "script": "66" },
        { "label": "滚", "script": "44" }
      ]
    },
    "blank": {
      "label": "空白模板（自定义起点）",
      "gameHints": [],
      "moves": [
        { "label": "1", "script": "P" },
        { "label": "2", "script": "K" },
        { "label": "3", "script": "236+P" },
        { "label": "4", "script": "623+P" },
        { "label": "5", "script": "" },
        { "label": "6", "script": "" }
      ]
    }
  }
}
''';

/// Convenience for callers that just want *some* valid config without
/// caring where it came from.
SpecialMovesConfig defaultConfigOrAsset(String filesDir) =>
    SpecialMovesFile.tryLoad(filesDir) ??
    SpecialMovesConfig.fromJsonString(assetsDefaultMovesJson);