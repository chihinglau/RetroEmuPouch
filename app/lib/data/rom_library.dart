import 'dart:convert';
import 'dart:io';

import '../domain/rom_entry.dart';

/// rom_index.json persistence inside filesDir.
/// A corrupt index is quarantined as `.corrupt-<timestamp>` and the app starts
/// with an empty library instead of crashing (same policy as the OORA project).
class RomLibrary {
  RomLibrary(this.filesDir);

  final String filesDir;

  File get _indexFile => File('$filesDir/rom_index.json');
  File get _metaFile => File('$filesDir/library/metadata.json');
  File get _cloudMetaFile => File('$filesDir/library/cloud_metadata.json');
  File get _cheatFile => File('$filesDir/library/cheats.json');
  File get _cloudCheatFile => File('$filesDir/library/cloud_cheats.json');

  Future<List<RomEntry>> load() async {
    final f = _indexFile;
    if (!f.existsSync()) return [];
    try {
      final raw = await f.readAsString();
      final j = jsonDecode(raw);
      if (j is! List) throw const FormatException('index root is not a list');
      final entries = j
          .whereType<Map<String, dynamic>>()
          .map(RomEntry.fromJson)
          .toList();
      await _applyMetadata(entries);
      await _applyCheats(entries);
      return entries;
    } catch (_) {
      try {
        await f.copy('$filesDir/rom_index.corrupt-${DateTime.now().millisecondsSinceEpoch}.json');
      } catch (_) {/* best effort */}
      return [];
    }
  }

  Map<String, dynamic>? _readByCrc(File f) {
    if (!f.existsSync()) return null;
    try {
      final j = jsonDecode(f.readAsStringSync());
      if (j is Map && j['byCrc'] is Map) {
        return (j['byCrc'] as Map).cast<String, dynamic>();
      }
    } catch (_) {/* malformed metadata must never break the library */}
    return null;
  }

  /// Merges PC-synced metadata (`library/metadata.json`, ADB push) and cloud
  /// metadata (`library/cloud_metadata.json`, network sync), both keyed by
  /// uppercase CRC32, into index entries. Index fields always win; the ADB
  /// snapshot outranks the cloud snapshot on conflicts. Cover paths are only
  /// applied when the image file really exists.
  Future<void> _applyMetadata(List<RomEntry> entries) async {
    final local = _readByCrc(_metaFile);
    final cloud = _readByCrc(_cloudMetaFile);
    if (local == null && cloud == null) return;

    String? str(dynamic v) =>
        v is String && v.trim().isNotEmpty ? v.trim() : null;

    for (final e in entries) {
      final lm = local?[e.crcKey];
      final cm = cloud?[e.crcKey];
      String? pick(String key) =>
          str(lm is Map ? lm[key] : null) ?? str(cm is Map ? cm[key] : null);

      e.genre ??= pick('genre');
      e.developer ??= pick('developer');
      e.publisher ??= pick('publisher');
      e.releaseDate ??= pick('releaseDate');
      e.region ??= pick('region');
      e.players ??= pick('players');
      e.description ??= pick('description');
      e.category ??= pick('category');
      final cover = pick('cover');
      if (cover != null) {
        final cf = File('$filesDir/$cover');
        if (cf.existsSync()) e.coverRelative = cover;
      }
    }
  }

  /// Merges PC-synced / in-emulator-authored cheats (`library/cheats.json`)
  /// and cloud cheats (`library/cloud_cheats.json`) into entries for display.
  /// The local snapshot wins when it actually contains commands.
  Future<void> _applyCheats(List<RomEntry> entries) async {
    final local = _readByCrc(_cheatFile);
    final cloud = _readByCrc(_cloudCheatFile);
    if (local == null && cloud == null) return;

    List<CheatInfo> parse(dynamic raw) => (raw is List)
        ? raw
            .whereType<Map<String, dynamic>>()
            .map(CheatInfo.fromJson)
            .where((c) => c.isChoice ? c.options.isNotEmpty : c.code.isNotEmpty)
            .toList(growable: false)
        : const <CheatInfo>[];

    for (final e in entries) {
      final localCheats = parse(local?[e.crcKey]);
      if (localCheats.isNotEmpty) {
        e.cheats = localCheats;
        continue;
      }
      final cloudCheats = parse(cloud?[e.crcKey]);
      if (cloudCheats.isNotEmpty) e.cheats = cloudCheats;
    }
  }

  Future<void> save(List<RomEntry> entries) async {
    final payload =
        const JsonEncoder.withIndent('  ').convert(entries.map((e) => e.toJson()).toList());
    await _indexFile.writeAsString(payload, flush: true);
  }

  /// Adds an entry unless the same relative path already exists (idempotent).
  List<RomEntry> upsert(List<RomEntry> entries, RomEntry entry) {
    final out = entries.where((e) => e.relativePath != entry.relativePath).toList()
      ..add(entry)
      ..sort((a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()));
    return out;
  }

  List<RomEntry> remove(List<RomEntry> entries, RomEntry entry) {
    final out = entries.where((e) => e.relativePath != entry.relativePath).toList();
    // best effort file removal
    final f = File('$filesDir/${entry.relativePath}');
    if (f.existsSync()) {
      try {
        f.deleteSync();
      } catch (_) {/* index is source of truth; keep UI usable */}
    }
    return out;
  }

  /// Raw cheat command maps (as stored in `cheats.json`) for [crcKey],
  /// merging local + cloud snapshots (local wins). Used by the package
  /// exporter so a shared package carries the game's 金手指.
  List<Map<String, dynamic>> cheatCommandsForCrc(String crcKey) {
    final local = _readByCrc(_cheatFile);
    final cloud = _readByCrc(_cloudCheatFile);
    final lp = local?[crcKey];
    if (lp is List && lp.isNotEmpty) {
      return lp.whereType<Map<String, dynamic>>().toList();
    }
    final cp = cloud?[crcKey];
    if (cp is List) return cp.whereType<Map<String, dynamic>>().toList();
    return const [];
  }

  /// Merges an incoming `{ crcKey: [commands] }` map into the local
  /// `library/cheats.json` store (incoming keys overwrite existing). Used by
  /// the package importer; atomic temp+rename so a corrupt write never
  /// destroys existing cheats.
  Future<void> mergeCheatsByCrc(Map<String, dynamic> incoming) async {
    final f = _cheatFile;
    Map<String, dynamic> root;
    if (f.existsSync()) {
      try {
        final j = jsonDecode(await f.readAsString());
        root = j is Map ? Map<String, dynamic>.from(j) : <String, dynamic>{};
      } catch (_) {
        root = <String, dynamic>{};
      }
    } else {
      root = <String, dynamic>{};
    }
    final byCrc = (root['byCrc'] is Map)
        ? Map<String, dynamic>.from(root['byCrc'] as Map)
        : <String, dynamic>{};
    incoming.forEach((k, v) {
      if (v is List && v.isNotEmpty) byCrc[k] = v;
    });
    root['version'] = 1;
    root['byCrc'] = byCrc;
    final tmp = File('${f.path}.tmp');
    await tmp.parent.create(recursive: true);
    await tmp.writeAsString(const JsonEncoder.withIndent('  ').convert(root),
        flush: true);
    await tmp.rename(f.path);
  }
}
