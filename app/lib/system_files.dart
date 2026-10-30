// System/BIOS validation for the libretro runner.
//
// Compliance (R1): the app ships NO copyrighted BIOS or ROM binaries. Cores
// such as FBA-2012 / FBNeo look up BIOS files (e.g. `neogeo.zip`) in the
// device-private `filesDir/system/` directory. Those files MUST be supplied by
// the user from their own legitimate copies — this module only *checks* for
// their presence and reports what is missing so the UI can prompt for an
// import. It never extracts a bundled blob.
//
// Location note: different cores expect the BIOS in different places *under*
// `filesDir/system/`:
//   - fbalpha2012 / fbneo read it straight from the system dir root.
//   - libretro MAME derives its rompath as `<system>/mame/roms`, so its BIOS
//     must live at `<system>/mame/roms/neogeo.zip` (confirmed by the core's
//     `-artpath .../system/mame/artwork` / `-hashpath .../system/mame/hash`
//     startup lines). A file placed only at the root is invisible to MAME and
//     the machine fails with "Required files are missing". [syncAll] mirrors a
//     user-supplied blob into every location any installed core needs.
import 'dart:io';

import 'pal/platform_pal.dart';

class SystemFiles {
  /// BIOS blobs the user must provide from their own legitimate copies, keyed
  /// by the libretro `coreId` that needs them. File names match what the cores
  /// look up in the system directory (compared case-insensitively).
  ///
  /// `qsound.zip` is **MAME-only**: it holds `dl-1425.bin`, the Q-Sound BIOS
  /// the libretro MAME core needs for every CPS-1 / CPS-2 game (1944, samsho,
  /// sf2ce, msh, …). FBA-2012 / FBNeo ship their own QSound emulation and
  /// never look up the BIOS blob, so listing it for those cores only spams
  /// the "missing BIOS" guidance with a file the user can't actually fix
  /// (the core won't read it). `LockedRom.ensureArcadeBiosInRomCache` walks
  /// the union of this map so the on-launch mirror step covers qsound.zip
  /// for MAME and silently skips it for the others.
  /// Every BIOS / system blob the app **supports** — recognises on import,
  /// lists in the settings manager, validates in the peer `bios` API, and
  /// mirrors into each core's lookup dir when present. The user supplies these
  /// from their own legitimate copies; the app never ships them. Per-driver
  /// requirements (CPS-1/2 need `qsound.zip` / `qsound_hle.zip`; IGS PolyGame
  /// Master needs `pgm.zip`; NeoGeo needs `neogeo.zip`) are resolved by the
  /// core itself, so this is the superset across all arcade cores.
  static const List<String> supportedBios = [
    'neogeo.zip',
    'qsound.zip',
    'qsound_hle.zip',
    'pgm.zip',
  ];

  /// BIOS blobs a given libretro [coreId] **must** have before it can boot.
  /// This is the hard gate used by [missingForCore] / [checkMissing] to block a
  /// launch (and prompt for an import) up front, instead of letting the core
  /// fail late with an obscure missing-file screen. For `mame` we require the
  /// full arcade BIOS set — NeoGeo (`neogeo.zip`), CPS-1/2 Q-Sound
  /// (`qsound.zip` / `qsound_hle.zip`) and IGS PolyGame Master (`pgm.zip`) —
  /// because the MAME core only resolves per-driver needs at boot, so requiring
  /// them pre-launch gives one clean import prompt covering every arcade title.
  /// [supportedBios] is the wider set used for recognition / staging / the peer
  /// `bios` API.
  static const Map<String, List<String>> requiredBios = {
    'fbalpha2012': ['neogeo.zip'],
    'fbneo': ['neogeo.zip'],
    'mame': ['neogeo.zip', 'qsound.zip', 'qsound_hle.zip', 'pgm.zip'],
  };

  /// Where each core expects its BIOS files, relative to `<filesDir>/system/`.
  /// Empty string means the system dir root (fbalpha2012 / fbneo); libretro
  /// MAME needs `<system>/mame/roms` (see file-level note).
  static const Map<String, String> _biosSubdir = {
    'fbalpha2012': '',
    'fbneo': '',
    'mame': 'mame/roms',
  };

  /// Every supported BIOS name (see [supportedBios]). Used for import
  /// validation, the settings manager, the peer `bios` API and the on-launch
  /// mirror step — the wider "supported" set, not the per-core hard gate.
  static List<String> biosNames() => List<String>.from(supportedBios);

  /// Internal alias of [biosNames] (retained for in-file callers such as
  /// [syncAll]).
  static List<String> _biosNames() => biosNames();

  /// Distinct system directories (including the root '') that any installed
  /// core reads BIOS from. Used to locate / mirror known BIOS blobs.
  static List<String> systemDirs() {
    final dirs = <String>{''};
    for (final sub in _biosSubdir.values) {
      if (sub.isNotEmpty) dirs.add(sub);
    }
    return dirs.toList();
  }

  /// Absolute path of [name] under [subdir] (relative to [baseDir]).
  static String _pathFor(String baseDir, String subdir, String name) =>
      subdir.isEmpty ? '$baseDir/$name' : '$baseDir/$subdir/$name';

  /// True when [name] is present in any of the system lookup dirs.
  static bool hasBios(String baseDir, String name) {
    for (final subdir in systemDirs()) {
      if (_present(baseDir, subdir, name)) return true;
    }
    return false;
  }

  /// Copy a user-supplied BIOS blob found at the system root into every other
  /// location the installed cores read from (e.g. `mame/roms`). Safe to call
  /// after landing a BIOS; it only writes the targets that are missing.
  static Future<void> syncToNeededLocations(String baseDir, String name) async {
    final src = File(_pathFor(baseDir, '', name));
    if (!src.existsSync()) return;
    for (final entry in requiredBios.entries) {
      if (!entry.value.contains(name)) continue;
      final subdir = _biosSubdir[entry.key] ?? '';
      if (subdir.isEmpty) continue;
      final dst = File(_pathFor(baseDir, subdir, name));
      if (dst.existsSync()) continue;
      try {
        await dst.parent.create(recursive: true);
        await src.copy(dst.path);
      } catch (e) {
        // ignore: avoid_print
        print('BIOS sync failed for $name -> $subdir: $e');
      }
    }
  }

  static bool _present(String baseDir, String subdir, String name) =>
      File(_pathFor(baseDir, subdir, name)).existsSync();

  /// Absolute path of the first existing copy of [name] under [baseDir] in any
  /// known lookup dir (system root or a per-core subdir such as `mame/roms`),
  /// or null when the blob is not installed anywhere. Used by the resource
  /// package exporter to locate the file to bundle regardless of where the
  /// user originally dropped it.
  static String? biosFilePath(String baseDir, String name) {
    for (final subdir in systemDirs()) {
      final f = File(_pathFor(baseDir, subdir, name));
      if (f.existsSync()) return f.path;
    }
    return null;
  }

  /// Returns the set of required BIOS file names that are NOT present where
  /// the relevant core looks for them. An empty result means everything needed
  /// is available; a non-empty result means at least one arcade core cannot
  /// boot until the user imports the missing file.
  static Future<Set<String>> checkMissing(PlatformPal pal) async {
    final baseDir = '${(await pal.filesDir())}/system';
    final base = Directory(baseDir);
    if (!base.existsSync()) {
      return {for (final names in requiredBios.values) ...names};
    }
    final missing = <String>{};
    for (final entry in requiredBios.entries) {
      final subdir = _biosSubdir[entry.key] ?? '';
      for (final name in entry.value) {
        if (!_present(baseDir, subdir, name)) missing.add(name);
      }
    }
    return missing;
  }

  /// BIOS blobs required by a specific libretro [coreId]. Empty for cores that
  /// boot without external system files (e.g. fceumm, gambatte, mgba).
  static List<String> requiredBiosFor(String coreId) =>
      requiredBios[coreId] ?? const [];

  /// Subset of [requiredBiosFor] that is NOT present where [coreId] looks for
  /// it. An empty set means the core can boot; a non-empty set means the launch
  /// should be blocked with a guidance dialog before handing off to the core,
  /// so the user sees an actionable "load this file" prompt instead of a raw
  /// core error overlay (e.g. mame's "missing neogeo.zip").
  static Future<Set<String>> missingForCore(
    PlatformPal pal,
    String coreId,
  ) async {
    final names = requiredBiosFor(coreId);
    if (names.isEmpty) return const {};
    final baseDir = '${(await pal.filesDir())}/system';
    final base = Directory(baseDir);
    if (!base.existsSync()) return {...names};
    final subdir = _biosSubdir[coreId] ?? '';
    return {
      for (final name in names)
        if (!_present(baseDir, subdir, name)) name
    };
  }

  /// Mirrors every user-supplied BIOS blob into each location the installed
  /// cores read from. A blob found in *any* known location (system root or a
  /// per-core subdir) is copied into every other required location, so the
  /// user only has to drop `neogeo.zip` once — whether into the root (what the
  /// UI prompts for) or directly into `mame/roms`. Safe to call on every scan;
  /// it only writes when a target is missing.
  static Future<void> syncAll(PlatformPal pal) async {
    final baseDir = '${(await pal.filesDir())}/system';
    final base = Directory(baseDir);
    if (!base.existsSync()) return;
    // Unique candidate directories: root ('') plus each non-empty subdir.
    final dirs = <String>{''};
    for (final sub in _biosSubdir.values) {
      if (sub.isNotEmpty) dirs.add(sub);
    }
    for (final name in _biosNames()) {
      File? src;
      for (final sub in dirs) {
        final f = File(_pathFor(baseDir, sub, name));
        if (f.existsSync()) {
          src = f;
          break;
        }
      }
      if (src == null) continue;
      for (final sub in dirs) {
        if (sub.isEmpty) continue; // root is the source we already have
        final dst = File(_pathFor(baseDir, sub, name));
        if (dst.existsSync()) continue;
        try {
          await dst.parent.create(recursive: true);
          await src.copy(dst.path);
        } catch (e) {
          print('BIOS sync failed for $name -> $sub: $e');
        }
      }
    }
  }
}
