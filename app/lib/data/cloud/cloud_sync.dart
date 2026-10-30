import 'dart:convert';
import 'dart:io';

import 'cloud_client.dart';
import 'cloud_config.dart';
import '../../config/app_channel.dart';

class SyncReport {
  SyncReport({
    required this.revision,
    required this.games,
    required this.romsAdded,
    required this.romsPresent,
    required this.coversAdded,
    required this.bytesDownloaded,
  });

  final int revision;
  final int games;
  final int romsAdded;
  final int romsPresent;
  final int coversAdded;
  final int bytesDownloaded;
}

/// Pulls the subscribed catalog snapshot and merges it into the on-device
/// library layout consumed by `RomLibrary`:
///   `library/cloud_metadata.json`  (byCrc, lower priority than ADB-synced data)
///   `library/cloud_cheats.json`    (byCrc)
///   `library/covers-cloud/<crc>.png`
///   `roms/cloud/<title>.<platform ext>`  (+ rom_index.json upsert)
class CloudSyncer {
  CloudSyncer({
    required this.client,
    required this.config,
    required this.filesDir,
  });

  final CloudClient client;
  final CloudConfig config;
  final String filesDir;

  static const _metaFields = [
    'title', 'platform', 'category', 'genre', 'developer', 'publisher',
    'releaseDate', 'players', 'region', 'description',
  ];

  String _safeFileName(String raw) {
    var s = raw
        .replaceAll(RegExp(r'[\\/:*?"<>|\x00-\x1f]'), '_')
        .replaceAll(RegExp(r'\s+'), ' ')
        .trim();
    if (s.length > 80) s = s.substring(0, 80);
    return s.isEmpty ? 'game' : s;
  }

  /// ROM container extension for a published platform id. Must match the
  /// platform/extension table the core resolver expects (PlatformKind).
  static String extForPlatform(String platform) => switch (platform) {
        'fds' => '.fds',
        'gameBoy' => '.gb',
        'gba' => '.gba',
        'atari2600' => '.a26',
        'masterSystem' => '.sms',
        'genesis' => '.md',
        // M6: arcade (Kawaks CPS1/CPS2/NeoGeo) is zipped — the runner
        // (libretro FBA-2012) opens the file directly and recognises it as
        // a MAME ROM set by extension. The lockfile wrapper around it stays
        // a single-entry ZIP regardless.
        'mame' || 'neogeo' => '.zip',
        _ => '.nes',
      };

  Future<SyncReport> sync({
    void Function(String stage, double? progress)? onProgress,
  }) async {
    onProgress?.call('正在获取游戏目录…', null);
    final payload = await client.syncLibrary();
    final revision = (payload['revision'] as num?)?.toInt() ?? 0;
    final games = (payload['games'] as List? ?? const [])
        .whereType<Map>()
        .map((m) => m.cast<String, dynamic>())
        .toList();

    final libDir = Directory('$filesDir/library');
    await libDir.create(recursive: true);

    // ---- 1. metadata + cheats snapshots ---------------------------------
    // Snapshot files accumulate across accounts/syncs: switching the logged-in
    // account (or syncing a narrower subscription) must not erase cheats /
    // metadata for games already downloaded on this device — ROMs themselves
    // are never removed by sync either. Every CRC in the fresh payload is
    // upserted (an empty cheats list means the PC side removed them and clears
    // that CRC); CRCs absent from this payload stay untouched.
    final byCrcMeta = await _readByCrc('$filesDir/library/cloud_metadata.json');
    final byCrcCheats = await _readByCrc('$filesDir/library/cloud_cheats.json');
    for (final g in games) {
      final crc = (g['crc'] as String? ?? '').toUpperCase();
      if (crc.isEmpty) continue;
      final meta = <String, dynamic>{};
      for (final k in _metaFields) {
        final v = g[k];
        if (v is String && v.trim().isNotEmpty) meta[k] = v.trim();
      }
      byCrcMeta[crc] = meta; // cover path is patched after image download
      final cheats = g['cheats'];
      if (cheats is List && cheats.isNotEmpty) {
        byCrcCheats[crc] = cheats;
      } else {
        byCrcCheats.remove(crc);
      }
    }
    await _writeJson('$filesDir/library/cloud_metadata.json',
        {'version': 1, 'byCrc': byCrcMeta});
    await _writeJson('$filesDir/library/cloud_cheats.json',
        {'version': 1, 'byCrc': byCrcCheats});

    // ---- 2. index + covers + ROMs ---------------------------------------
    final indexFile = File('$filesDir/rom_index.json');
    final index = <Map<String, dynamic>>[];
    if (indexFile.existsSync()) {
      try {
        final raw = jsonDecode(await indexFile.readAsString());
        if (raw is List) {
          index.addAll(raw.whereType<Map>().map((e) =>
              Map<String, dynamic>.from(e.cast<String, dynamic>())));
        }
      } catch (_) {/* index quarantined by RomLibrary; rebuild fresh */}
    }
    final existingCrcs = index
        .map((e) => (e['crc32'] is num
                ? (e['crc32'] as num).toInt()
                : int.tryParse('${e['crc32']}') ?? 0) &
            0xFFFFFFFF)
        .map((v) =>
            v.toRadixString(16).padLeft(8, '0').toUpperCase())
        .toSet();
    final existingPaths =
        index.map((e) => e['relativePath'] as String? ?? '').toSet();

    var romsAdded = 0;
    var romsPresent = 0;
    var coversAdded = 0;
    var bytesDownloaded = 0;

    final coverDir = Directory('$filesDir/library/covers-cloud');
    await coverDir.create(recursive: true);
    final romsDir = Directory('$filesDir/roms/cloud');
    await romsDir.create(recursive: true);

    for (var i = 0; i < games.length; i++) {
      final g = games[i];
      final crc = (g['crc'] as String? ?? '').toUpperCase();
      if (crc.isEmpty) continue;
      final title = (g['title'] as String?)?.trim().isNotEmpty == true
          ? (g['title'] as String).trim()
          : crc;
      final platform = (g['platform'] as String?) ?? 'nes';
      final base = _safeFileName(title);

      // cover (best effort; the catalog tolerates missing art)
      if (g['cover'] != null) {
        final coverFile = File('$filesDir/library/covers-cloud/$crc.png');
        if (!coverFile.existsSync()) {
          try {
            await client.downloadCover(crc, dest: coverFile);
            if (coverFile.existsSync() && coverFile.lengthSync() > 0) {
              coversAdded++;
              (byCrcMeta[crc] as Map<String, dynamic>)['cover'] =
                  'library/covers-cloud/$crc.png';
            } else {
              coverFile.deleteSync();
            }
          } catch (_) {
            try {
              if (coverFile.existsSync()) coverFile.deleteSync();
            } catch (_) {/* ignore */}
          }
        } else {
          (byCrcMeta[crc] as Map<String, dynamic>)['cover'] =
              'library/covers-cloud/$crc.png';
        }
      }

      // ROM
      if (existingCrcs.contains(crc)) {
        romsPresent++;
        continue;
      }
      // R1: store channels must not download game binaries — they only
      // catalogue the entry (covers/metadata handled above) and continue.
      if (!appChannel.canCloudRom) {
        romsPresent++;
        continue;
      }
      final ext = extForPlatform(platform.toLowerCase());
      var rel = 'roms/cloud/$base$ext';
      var n = 2;
      while (existingPaths.contains(rel)) {
        rel = 'roms/cloud/$base ($n)$ext';
        n++;
      }
      final romFile = File('$filesDir/$rel');
      onProgress?.call('下载游戏 $title（${i + 1}/${games.length}）…', null);
      try {
        final size = await client.downloadRom(crc, dest: romFile,
                  onProgress: (p, got, total) {
                if (p >= 0) {
                  onProgress?.call(
                      '下载游戏 $title（${i + 1}/${games.length}）…', p);
                }
              });
              bytesDownloaded += size;
              final crcInt = int.parse(crc, radix: 16);
              // `size` here is the byte count of the MGS1-encrypted ZIP that came
              // off the wire; the catalog entry's `size` is the decrypted plaintext.
              // The library UI shows plaintext size so a 64KB NES ROM doesn't look
              // like a 16KB blob.
              final plainSize = (g['size'] as num?)?.toInt() ?? size;
              index.add({
                'name': '$base$ext',
                'originalName': title,
                'relativePath': rel,
                'size': plainSize,
                'crc32': crcInt,
                'platform': platform == 'fds' ? 'nes' : platform,
                'importedAt': DateTime.now().toIso8601String(),
              });
        existingCrcs.add(crc);
        existingPaths.add(rel);
        romsAdded++;
      } catch (e) {
        try {
          if (romFile.existsSync()) romFile.deleteSync();
        } catch (_) {/* ignore */}
        rethrow; // surface the failure; metadata already reflects intent
      }
    }

    // ---- 3. persist ------------------------------------------------------
    await _writeJson('$filesDir/library/cloud_metadata.json',
        {'version': 1, 'byCrc': byCrcMeta});
    index.sort((a, b) =>
        (a['name'] as String? ?? '').toLowerCase().compareTo(
            (b['name'] as String? ?? '').toLowerCase()));
    await _writeJson('$filesDir/rom_index.json', index);
    config.lastRevision = revision;
    await config.save();

    return SyncReport(
      revision: revision,
      games: games.length,
      romsAdded: romsAdded,
      romsPresent: romsPresent,
      coversAdded: coversAdded,
      bytesDownloaded: bytesDownloaded,
    );
  }

  /// Loads a `{version, byCrc}` snapshot's byCrc map; empty/missing/corrupt
  /// files start from an empty map so a sync can always rebuild/merge.
  Future<Map<String, dynamic>> _readByCrc(String path) async {
    final f = File(path);
    if (!f.existsSync()) return <String, dynamic>{};
    try {
      final raw = jsonDecode(await f.readAsString());
      if (raw is Map && raw['byCrc'] is Map) {
        return (raw['byCrc'] as Map).cast<String, dynamic>();
      }
    } catch (_) {/* corrupt snapshot — rebuild from scratch */}
    return <String, dynamic>{};
  }

  Future<void> _writeJson(String path, Object data) async {
    final f = File(path);
    await f.parent.create(recursive: true);
    await f.writeAsString(
        const JsonEncoder.withIndent('  ').convert(data),
        flush: true);
  }
}
