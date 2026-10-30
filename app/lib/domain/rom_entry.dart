import 'dart:io' show Platform;

import '../config/app_channel.dart';

/// OpenHarmony ships only the MAME core (`libgs_mame.so`). `libgs_fbalpha2012.so`
/// is not part of the HAP, so routing arcade games to FBA-2012 in a
/// `--dart-define=CHANNEL=community` build made every arcade launch die inside
/// `dlopen()` (silent blue screen before the error overlay existed).
bool get _isOhos => Platform.operatingSystem == 'ohos';

/// Supported platform families. Only NES is implemented end-to-end in M2/M3;
/// the remaining ids are reserved for later milestones.
enum PlatformKind {
  nes,
  snes,
  gameBoy,
  gba,
  n64,
  nds,
  atari2600,
  masterSystem,
  genesis,
  ps1,
  psp,
  neogeo,
  mame,
  saturn,
  wii,
  unknown;

  String get label => switch (this) {
        PlatformKind.nes => 'NES / FC',
        PlatformKind.snes => 'SNES',
        PlatformKind.gameBoy => 'Game Boy',
        PlatformKind.gba => 'GBA',
        PlatformKind.n64 => 'N64',
        PlatformKind.nds => 'NDS',
        PlatformKind.atari2600 => 'Atari 2600',
        PlatformKind.masterSystem => 'Master System',
        PlatformKind.genesis => 'Genesis / MD',
        PlatformKind.ps1 => 'PlayStation 1',
        PlatformKind.psp => 'PSP',
        PlatformKind.neogeo => 'Neo Geo',
        PlatformKind.mame => 'MAME',
        PlatformKind.saturn => 'Sega Saturn',
        PlatformKind.wii => 'Wii',
        PlatformKind.unknown => '未知',
      };

  /// libretro core id used by the native runner.
  /// M4 (8/16-bit batch): fceumm / gambatte / mgba / picodrive / stella2014.
  /// M6 (arcade): `fbalpha2012` (libretro FBA-2012, MAME 0.114 driver database,
  /// bundled as the prebuilt `libgs_fbalpha2012.so` in `jniLibs/`). Both
  /// [neogeo] and [mame] (CPS1/CPS2) are routed through this core.
  ///
  /// Note on WinKawaks compatibility: FBA-2012 expects the file-name convention
  /// of MAME 0.114 (`232-p1.p1`, `41-1m.3a`), while WinKawaks 1.45 ships an
  /// older MAME 0.94 dump (`232-p1.bin`, `41_19.rom`). The `LockedRom`
  /// materialiser rewrites internal zip entries to the FBA-2012 names when
  /// it detects an arcade game, so the cache-zip contains both (a) the
  /// required MAME 0.114 names FBA looks up by default and (b) a sidecar
  /// `neogeo.zip` in `rom_cache/` for the FBA BIOS, so a WinKawaks lockfile
  /// round-trips end-to-end.
  String? get coreId => switch (this) {
        PlatformKind.nes => 'fceumm',
        PlatformKind.gameBoy => 'gambatte',
        PlatformKind.gba => 'mgba',
        PlatformKind.atari2600 => 'stella2014',
        PlatformKind.masterSystem || PlatformKind.genesis => 'picodrive',
        // FBA-2012 is non-commercial (FB Alpha / FinalBurn Neo license), so
        // it is packaged in the `community` flavour only. Store builds use
        // MAME instead: >= 0.197 is dual-licensed BSD-3-Clause /
        // GPL-2.0-or-later, so the BSD option permits commercial
        // distribution (attribution only). Built by scripts/build-mame.ps1
        // from github.com/libretro/mame for android-arm64.
        // `fbalpha2012` only exists on Android (community flavour). OHOS must
        // always use MAME, even when the channel flag says community.
        PlatformKind.mame || PlatformKind.neogeo =>
            (appChannel.isStore || _isOhos) ? 'mame' : 'fbalpha2012',
        _ => null,
      };
}

/// Derives a [PlatformKind] from the *zip's parent directory* when the zip
/// belongs to a known arcade collection (Kawaks-style Cps1/Cps2/NeoGeo),
/// otherwise from the extension.
///
/// [relativePath] is the on-device relative path. Both the English folder
/// names (`roms/Cps1/1941.zip`) and the shipped Chinese collection names
/// (`roms/街机 CPS1 经典/1941r1.zip`, `roms/街机 NeoGeo 经典/kof97.zip`)
/// are recognised. Cloud-synced ROMs live in a flat `roms/cloud/` folder
/// and carry their platform explicitly in `rom_index.json` instead.
PlatformKind platformFromExtension(String name, [String? relativePath]) {
  final rp = relativePath ?? name;
  final rpLower = rp.toLowerCase();
  if (rpLower.endsWith('.zip')) {
    // Match a path SEGMENT so a game file name itself can never trigger the
    // rule (e.g. an unrelated "...cps1....zip" at the top level). CPS is
    // checked first: Capcom collections are 6-button panels, everything
    // else under an arcade folder is treated as the NeoGeo 4-button panel.
    final segments = rpLower.split(RegExp(r'[/\\]'));
    if (segments.any((s) => s.contains('cps1') || s.contains('cps2'))) {
      return PlatformKind.mame;
    }
    if (segments.any((s) => s.contains('neogeo'))) {
      return PlatformKind.neogeo;
    }
  }
  final ext = name.contains('.') ? name.split('.').last.toLowerCase() : '';
  return switch (ext) {
    'nes' || 'fds' || 'unf' || 'unif' => PlatformKind.nes,
    'sfc' || 'smc' => PlatformKind.snes,
    'gb' || 'gbc' || 'sgb' => PlatformKind.gameBoy,
    'gba' => PlatformKind.gba,
    'z64' || 'n64' || 'v64' => PlatformKind.n64,
    'nds' => PlatformKind.nds,
    'a26' => PlatformKind.atari2600,
    'sms' || 'gg' || 'sg' => PlatformKind.masterSystem,
    'md' || 'gen' || 'smd' || '32x' => PlatformKind.genesis,
    'cue' || 'pbp' || 'mdf' || 'img' => PlatformKind.ps1,
    'iso' || 'cso' => PlatformKind.psp,
    'zip' => PlatformKind.neogeo, // generic .zip treated as MVS
    _ => PlatformKind.unknown,
  };
}

/// A named value/equipment option inside a choice cheat command.
class CheatOption {
  CheatOption({required this.label, required this.code});

  final String label;
  final String code; // core syntax: GG / XXXX:XX / XXXX?XX:XX / 8-hex PAR

  Map<String, dynamic> toJson() => {'label': label, 'code': code};

  factory CheatOption.fromJson(Map<String, dynamic> j) => CheatOption(
        label: (j['label'] as String?)?.trim().isNotEmpty == true
            ? j['label'] as String
            : (j['code'] as String? ?? ''),
        code: (j['code'] as String? ?? '').trim(),
      );
}

/// A user-facing cheat command authored on the PC manager and synced to the
/// phone. Players never type codes: a command is either a simple switch
/// (无限生命, on/off) or a choice (武力值=10/50/100, 装备=剑/枪).
class CheatInfo {
  CheatInfo({
    required this.name,
    this.code = '',
    this.enabled = false,
    this.options = const [],
    this.selected = -1,
  }) : isChoice = options.isNotEmpty;

  String name;
  final bool isChoice;

  // switch fields
  final String code;
  bool enabled;

  // choice fields
  final List<CheatOption> options;
  int selected; // active option index, -1 = off

  bool get isActive => isChoice ? selected >= 0 : enabled;
  String? get activeCode => isChoice
      ? (selected >= 0 && selected < options.length ? options[selected].code : null)
      : (enabled ? code : null);

  /// Short status for read-only lists, e.g. 「已启用」/「关」/「100」.
  String get statusLabel {
    if (!isChoice) return enabled ? '已启用' : '关';
    return selected >= 0 && selected < options.length
        ? options[selected].label
        : '关';
  }

  Map<String, dynamic> toJson() => isChoice
      ? {
          'name': name,
          'kind': 'choice',
          'selected': selected,
          'options': options.map((o) => o.toJson()).toList(),
        }
      : {'name': name, 'kind': 'switch', 'code': code, 'enabled': enabled};

  factory CheatInfo.fromJson(Map<String, dynamic> j) {
    final name = (j['name'] as String?)?.trim().isNotEmpty == true
        ? j['name'] as String
        : (j['code'] as String? ?? '');
    final opts = (j['options'] as List?)
            ?.whereType<Map>()
            .map((m) => CheatOption.fromJson(m.cast<String, dynamic>()))
            .where((o) => o.code.isNotEmpty)
            .toList() ??
        const [];
    // kind 'choice' is explicit; any options-bearing legacy entry also counts.
    if (j['kind'] == 'choice' || opts.isNotEmpty) {
      final sel = j['selected'] is int ? j['selected'] as int : -1;
      return CheatInfo(
        name: name,
        options: opts,
        selected: (sel >= 0 && sel < opts.length) ? sel : -1,
      );
    }
    return CheatInfo(
      name: name,
      code: (j['code'] as String? ?? '').trim(),
      enabled: j['enabled'] == true,
    );
  }
}

class RomEntry {
  RomEntry({
    required this.name,
    required this.originalName,
    required this.relativePath,
    required this.size,
    required this.crc32,
    required this.importedAt,
    this.lastPlayedAt,
    this.genre,
    this.developer,
    this.publisher,
    this.releaseDate,
    this.region,
    this.players,
    this.description,
    this.category,
    this.coverRelative,
    PlatformKind? platform,
  }) : platform = platform ?? platformFromExtension(name, relativePath);

  final String name;
  final String originalName;
  final String relativePath;
  final int size;
  final int crc32;
  final DateTime importedAt;
  DateTime? lastPlayedAt;
  final PlatformKind platform;

  // ---- Optional metadata (synced from the PC manager; tolerate missing) ----
  String? genre;
  String? developer;
  String? publisher;
  String? releaseDate; // "YYYY-MM" or "YYYY"
  String? region;
  String? players;
  String? description;
  String? category;
  String? coverRelative; // path relative to filesDir, e.g. library/covers/x.png

  /// Cheats from library/cheats.json (PC-synced or authored in-emulator).
  /// Transient: the library view never writes this file back to the device.
  List<CheatInfo> cheats = const [];

  /// Unsigned 8-hex CRC32 used as metadata key by the PC manager.
  String get crcKey =>
      (crc32 & 0xFFFFFFFF).toRadixString(16).padLeft(8, '0').toUpperCase();

  /// Display title prefers the human-friendly original name, falling back to
  /// the stored file name.
  ///
  /// OHOS SAF imports historically stored percent-encoded names (the ArkTS side
  /// did not URL-decode the picked document URI), so an old entry may hold e.g.
  /// `%E6%8B%B3%E7%9A%87%2097.zip` instead of `拳皇 97.zip`. Decoding here heals
  /// those existing entries at render time; freshly imported names are already
  /// decoded and pass through unchanged (no `%`), so this is idempotent.
  String get displayTitle =>
      _decodePercent(originalName.isNotEmpty ? originalName : name);

  static String _decodePercent(String s) {
    if (!s.contains('%')) return s;
    try {
      final decoded = Uri.decodeComponent(s);
      return decoded.isEmpty ? s : decoded;
    } catch (_) {
      return s; // malformed escape -> keep the raw name
    }
  }

  /// File name to use when keying the multiplayer catalog / emulator driver
  /// databases: [originalName] holds the real driver zip name (e.g.
  /// `kof97.zip`) while [name] may be a localised display name (e.g.
  /// `拳皇97.zip`) that never matches a driver key.
  String get driverFileName =>
      originalName.isNotEmpty ? originalName : name;

  Map<String, dynamic> toJson() => {
        'name': name,
        'originalName': originalName,
        'relativePath': relativePath,
        'size': size,
        'crc32': crc32,
        'platform': platform.name,
        'importedAt': importedAt.toIso8601String(),
        'lastPlayedAt': lastPlayedAt?.toIso8601String(),
        'genre': genre,
        'developer': developer,
        'publisher': publisher,
        'releaseDate': releaseDate,
        'region': region,
        'players': players,
        'description': description,
        'category': category,
        'coverRelative': coverRelative,
      };

  factory RomEntry.fromJson(Map<String, dynamic> j) {
    String? str(dynamic v) => v is String && v.trim().isNotEmpty ? v : null;
    int? intVal(dynamic v) =>
        v is num ? v.toInt() : (v is String ? int.tryParse(v) : null);
    final fallbackName =
        (j['relativePath'] as String?)?.split('/').last ?? 'unknown.rom';
    return RomEntry(
      name: str(j['name']) ?? fallbackName,
      originalName: str(j['originalName']) ?? str(j['name']) ?? fallbackName,
      relativePath: str(j['relativePath']) ?? 'roms/$fallbackName',
      size: intVal(j['size']) ?? 0,
      crc32: intVal(j['crc32']) ?? 0,
      importedAt: DateTime.tryParse(j['importedAt'] as String? ?? '') ??
          DateTime.fromMillisecondsSinceEpoch(0),
      lastPlayedAt: j['lastPlayedAt'] == null
          ? null
          : DateTime.tryParse(j['lastPlayedAt'] as String? ?? ''),
      genre: str(j['genre']),
      developer: str(j['developer']),
      publisher: str(j['publisher']),
      releaseDate: str(j['releaseDate']),
      region: str(j['region']),
      players: str(j['players']),
      description: str(j['description']),
      category: str(j['category']),
      coverRelative: str(j['coverRelative']),
      platform: PlatformKind.values.firstWhere(
        (p) => p.name == j['platform'],
        orElse: () => platformFromExtension(
            str(j['name']) ?? fallbackName,
            str(j['relativePath']) ?? 'roms/$fallbackName'),
      ),
    );
  }
}
