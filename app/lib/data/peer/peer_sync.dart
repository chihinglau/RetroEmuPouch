import 'dart:io';

import '../cloud/cloud_sync.dart';
import '../../system_files.dart';
import 'peer_client.dart';
import 'peer_files.dart';
import '../../config/app_channel.dart';

/// One manual save slot advertised by the partner.
class RemoteSlot {
  RemoteSlot(
      {required this.slot, required this.size, required this.mtimeMs,
      required this.hasThumb});

  final int slot;
  final int size;
  final int? mtimeMs;
  final bool hasThumb;
}

/// A game entry from the partner's `/library` response.
class RemoteGame {
  RemoteGame(this.raw);

  final Map<String, dynamic> raw;

  String get crc => (raw['crc'] as String? ?? '').toUpperCase();
  String get name => raw['name'] as String? ?? '';
  String get nameCn =>
      (raw['name_cn'] as String?)?.trim().isNotEmpty == true
          ? (raw['name_cn'] as String).trim()
          : '';
  String get title =>
      nameCn.isNotEmpty
          ? nameCn
          : ((raw['originalName'] as String?)?.trim().isNotEmpty == true
              ? (raw['originalName'] as String).trim()
              : name);
  String get platform => raw['platform'] as String? ?? 'nes';
  int get romSize => (raw['size'] as num?)?.toInt() ?? 0;
  bool get hasCheats => raw['hasCheats'] == true;
  bool get hasBattery => raw['hasBattery'] == true;
  int get batterySize => (raw['batterySize'] as num?)?.toInt() ?? 0;
  int? get batteryMtime => (raw['batteryMtime'] as num?)?.toInt();
  bool get hasAuto => raw['hasAuto'] == true;
  int get autoSize => (raw['autoSize'] as num?)?.toInt() ?? 0;
  int? get autoMtime => (raw['autoMtime'] as num?)?.toInt();
  bool get hasCover => raw['hasCover'] == true;
  int get coverSize => (raw['coverSize'] as num?)?.toInt() ?? 0;

  Map<String, dynamic>? get metadata {
    final m = raw['metadata'];
    return m is Map ? m.cast<String, dynamic>() : null;
  }

  List<RemoteSlot> get slots => ((raw['slots'] as List?) ?? const [])
      .whereType<Map>()
      .map((m) => RemoteSlot(
            slot: (m['slot'] as num).toInt(),
            size: (m['size'] as num?)?.toInt() ?? 0,
            mtimeMs: (m['mtime'] as num?)?.toInt(),
            hasThumb: m['hasThumb'] == true,
          ))
      .toList();

  static List<RemoteGame> parseLibrary(Map<String, dynamic> payload) =>
      ((payload['games'] as List?) ?? const [])
          .whereType<Map>()
          .map((m) => RemoteGame(m.cast<String, dynamic>()))
          .toList();
}

/// What the user ticked for one game in the import sheet.
class PeerGameSelection {
  PeerGameSelection({
    required this.crc,
    this.rom = false,
    this.cheats = false,
    this.saveKinds = const {},
  });

  final String crc;
  bool rom;
  bool cheats;

  /// Subset of {'battery','auto','slot1'..'slot99'}.
  Set<String> saveKinds;
}

enum PeerResourceKind { rom, cheats, saveBattery, saveAuto, saveSlot, bios }

enum PeerItemAction { add, overwrite, skip }

enum PeerItemStatus { pending, done, failed, skipped }

/// A single downloadable action in the resolved import plan.
/// Cover/metadata ride along with the ROM silently (no conflict UI).
class PeerPlanItem {
  PeerPlanItem({
    required this.crc,
    required this.title,
    this.remote,
    required this.kind,
    this.slot,
    required this.remoteSize,
    this.remoteMtime,
    this.localMtime,
    required this.conflict,
    this.blocked = false,
    required this.action,
    this.status = PeerItemStatus.pending,
    this.error,
  });

  final String crc;
  final String title;
  final RemoteGame? remote;
  final PeerResourceKind kind;
  final int? slot;
  final int remoteSize;
  final int? remoteMtime;
  final int? localMtime;

  /// true when both sides already hold this resource.
  bool conflict;

  /// true when a running emulator owns this CRC's saves (AC-11).
  bool blocked;

  PeerItemAction action;
  PeerItemStatus status;
  String? error;

  bool get isSave =>
      kind == PeerResourceKind.saveBattery ||
      kind == PeerResourceKind.saveAuto ||
      kind == PeerResourceKind.saveSlot;

  String get kindLabel => switch (kind) {
        PeerResourceKind.rom => '游戏 ROM',
        PeerResourceKind.cheats => '金手指',
        PeerResourceKind.saveBattery => '电池存档',
        PeerResourceKind.saveAuto => '自动快照',
        PeerResourceKind.saveSlot => '槽位存档 ${slot ?? ''}',
        PeerResourceKind.bios => 'BIOS 文件',
      };

  /// Query value for the save endpoint, or null for non-save items.
  String? get saveApiKind => switch (kind) {
        PeerResourceKind.saveBattery => 'battery',
        PeerResourceKind.saveAuto => 'auto',
        PeerResourceKind.saveSlot => 'slot$slot',
        _ => null,
      };
}

class PeerImportReport {
  PeerImportReport({
    this.added = 0,
    this.skipped = 0,
    this.overwritten = 0,
    this.failed = 0,
    this.bytes = 0,
  });

  int added;
  int skipped;
  int overwritten;
  int failed;
  int bytes;
}

class PeerSpaceException implements Exception {
  PeerSpaceException(this.required, this.available);
  final int required;
  final int available;
  @override
  String toString() =>
      '空间不足：需要 $required 字节，可用 $available 字节';
}

/// Progress event during execution.
class PeerProgress {
  PeerProgress({
    required this.gameIndex,
    required this.gameCount,
    required this.label,
    required this.received,
    this.total,
  });

  final int gameIndex;
  final int gameCount;
  final String label;
  final int received;
  final int? total;
}

/// Builds the conflict plan and lands chosen files into the local library
/// layout (ROM → `roms/peer/`, cheats → cloud snapshot layer, saves →
/// `saves/`), mirroring CloudSyncer's naming/atomicity conventions.
class PeerImporter {
  PeerImporter({required this.filesDir, required this.client});

  final String filesDir;
  final PeerClient client;

  /// Safety headroom so a near-full partition does not fill to zero.
  static const int spaceMarginBytes = 16 * 1024 * 1024;

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

  // ------------------------------------------------------------- local state

  Future<Set<String>> _localCrcs() async {
    final f = File('$filesDir/rom_index.json');
    final j = PeerFiles.readJsonOrNull(f);
    if (j is! List) return {};
    return j.whereType<Map>().map((e) {
      final v = (e['crc32'] as num?)?.toInt() ?? 0;
      return (v & 0xFFFFFFFF)
          .toRadixString(16)
          .padLeft(8, '0')
          .toUpperCase();
    }).toSet();
  }

  /// Which snapshot layer holds cheats for [crc]: 'local' (player layer
  /// wins), 'cloud', or null.
  Future<String?> _cheatLayer(String crc) async {
    final local = PeerFiles.readJsonOrNull(
        File('$filesDir/library/cheats.json'));
    if (local is Map &&
        local['byCrc'] is Map &&
        (local['byCrc'] as Map)[crc] is List &&
        ((local['byCrc'] as Map)[crc] as List).isNotEmpty) {
      return 'local';
    }
    final cloud = PeerFiles.readJsonOrNull(
        File('$filesDir/library/cloud_cheats.json'));
    if (cloud is Map &&
        cloud['byCrc'] is Map &&
        (cloud['byCrc'] as Map)[crc] is List &&
        ((cloud['byCrc'] as Map)[crc] as List).isNotEmpty) {
      return 'cloud';
    }
    return null;
  }

  int? _mtimeIfExists(String relPath) {
    final f = File('$filesDir/$relPath');
    return f.existsSync()
        ? f.statSync().modified.millisecondsSinceEpoch
        : null;
  }

  String _saveRel(String crc, String apiKind) => switch (apiKind) {
        'battery' => 'saves/$crc.sav',
        'auto' => 'saves/$crc.state',
        _ => 'saves/$crc.$apiKind.state', // slotN
      };

  // ------------------------------------------------------------------- plan

  /// Resolve selections into an ordered, per-file plan with default
  /// decisions: new → add, existing → skip (saves carry the strong
  /// overwrite warning; local cheats always default to skip).
  Future<List<PeerPlanItem>> buildPlan({
    required List<RemoteGame> games,
    required List<PeerGameSelection> selections,
    Set<String> runningCrcs = const {},
    Map<String, int> biosToSync = const {},
  }) async {
    final selByCrc = {for (final s in selections) s.crc: s};
    final localCrcs = await _localCrcs();
    final items = <PeerPlanItem>[];

    for (final g in games) {
      final sel = selByCrc[g.crc];
      if (sel == null) continue;

      if (sel.rom) {
        final hasLocal = localCrcs.contains(g.crc);
        items.add(PeerPlanItem(
          crc: g.crc,
          title: g.title,
          remote: g,
          kind: PeerResourceKind.rom,
          remoteSize: g.romSize,
          conflict: hasLocal,
          action: hasLocal ? PeerItemAction.skip : PeerItemAction.add,
        ));
      }

      if (sel.cheats && g.hasCheats) {
        final layer = await _cheatLayer(g.crc);
        items.add(PeerPlanItem(
          crc: g.crc,
          title: g.title,
          remote: g,
          kind: PeerResourceKind.cheats,
          remoteSize: 0,
          conflict: layer != null,
          action: layer == null
              ? PeerItemAction.add
              : PeerItemAction.skip,
        ));
      }

      void addSave(PeerResourceKind kind, String apiKind, int size,
          int? remoteMtime, int? slot) {
        final blocked = runningCrcs.contains(g.crc);
        final localMtime = _mtimeIfExists(_saveRel(g.crc, apiKind));
        final exists = localMtime != null;
        items.add(PeerPlanItem(
          crc: g.crc,
          title: g.title,
          remote: g,
          kind: kind,
          slot: slot,
          remoteSize: size,
          remoteMtime: remoteMtime,
          localMtime: exists ? localMtime : null,
          conflict: exists,
          blocked: blocked,
          action: blocked
              ? PeerItemAction.skip
              : (exists ? PeerItemAction.skip : PeerItemAction.add),
        ));
      }

      if (sel.saveKinds.contains('battery') && g.hasBattery) {
        addSave(PeerResourceKind.saveBattery, 'battery', g.batterySize,
            g.batteryMtime, null);
      }
      if (sel.saveKinds.contains('auto') && g.hasAuto) {
        addSave(PeerResourceKind.saveAuto, 'auto', g.autoSize,
            g.autoMtime, null);
      }
      for (final slot in g.slots) {
        final key = 'slot${slot.slot}';
        if (!sel.saveKinds.contains(key)) continue;
        addSave(PeerResourceKind.saveSlot, key, slot.size, slot.mtimeMs,
            slot.slot);
      }
    }

    // BIOS blobs: not per-game, but required by the cores that run the games
    // the user is importing. Land them into system/ and mirror to every core
    // location so the imported games boot without a separate manual step.
    for (final entry in biosToSync.entries) {
      final name = entry.key;
      final present = SystemFiles.hasBios('$filesDir/system', name);
      items.add(PeerPlanItem(
        crc: name,
        title: name,
        kind: PeerResourceKind.bios,
        remoteSize: entry.value,
        conflict: present,
        action: present ? PeerItemAction.skip : PeerItemAction.add,
      ));
    }
    return items;
  }

  /// Sum bytes the plan still needs to transfer.
  int requiredBytes(List<PeerPlanItem> plan) => plan
      .where((i) =>
          i.action != PeerItemAction.skip &&
          i.status != PeerItemStatus.done)
      .fold(0, (sum, i) => sum + i.remoteSize);

  // --------------------------------------------------------------- execute

  /// Execute (or retry) [plan]. [availableBytes] is consulted before the
  /// first transfer; already-done items are never re-downloaded. When
  /// [isCancelled] returns true the loop stops between files — completed
  /// items stay done, untouched items stay pending (a later [execute] call
  /// resumes).
  Future<PeerImportReport> execute(
    List<PeerPlanItem> plan, {
    required int? Function() availableBytes,
    void Function(PeerProgress)? onProgress,
    bool Function()? isCancelled,
  }) async {
    final report = PeerImportReport();

    final pending = plan
        .where((i) =>
            i.action != PeerItemAction.skip &&
            i.status != PeerItemStatus.done)
        .toList();
    for (final i in plan) {
      if (i.action == PeerItemAction.skip &&
          i.status == PeerItemStatus.pending) {
        i.status = PeerItemStatus.skipped;
      }
    }
    report.skipped = plan
        .where((i) => i.status == PeerItemStatus.skipped)
        .length;

    if (pending.isEmpty) return report;

    // ---- space precheck (before any byte hits the disk) ----
    final need = requiredBytes(plan) + spaceMarginBytes;
    final free = availableBytes();
    if (free != null && need > free) {
      throw PeerSpaceException(need, free);
    }

    // ---- caches: index + byCrc layers ----
    final indexFile = File('$filesDir/rom_index.json');
    final index = <Map<String, dynamic>>[];
    final rawIndex = PeerFiles.readJsonOrNull(indexFile);
    if (rawIndex is List) {
      index.addAll(rawIndex
          .whereType<Map>()
          .map((e) => Map<String, dynamic>.from(e.cast<String, dynamic>())));
    }
    final existingCrcs = index
        .map((e) => ((e['crc32'] as num?)?.toInt() ?? 0) & 0xFFFFFFFF)
        .map((v) =>
            v.toRadixString(16).padLeft(8, '0').toUpperCase())
        .toSet();
    final existingPaths =
        index.map((e) => e['relativePath'] as String? ?? '').toSet();

    final metadata = _loadByCrc('library/cloud_metadata.json');
    final cloudCheats = _loadByCrc('library/cloud_cheats.json');

    final gameCount = pending.map((i) => i.crc).toSet().length;
    var gameSeen = 0;
    String? lastCrc;

    for (final item in pending) {
      if (isCancelled != null && isCancelled()) break;
      if (item.crc != lastCrc) {
        gameSeen++;
        lastCrc = item.crc;
      }
      void progress(int received, int? total) => onProgress?.call(PeerProgress(
            gameIndex: gameSeen,
            gameCount: gameCount,
            label: '${item.title} · ${item.kindLabel}',
            received: received,
            total: total,
          ));

      try {
        final wasOverwrite = item.conflict &&
            item.action == PeerItemAction.overwrite;
        switch (item.kind) {
          case PeerResourceKind.rom:
            // Capability guard. Partner ROM transfer is a direct LAN sharing of
            // a dump the user already owns (no server involvement), so it is
            // allowed on store too — unlike cloud fetch (canCloudRom). This is
            // kept so that withdrawing the capability still reports an honest
            // "skipped" instead of the old silent success-with-no-ROM.
            if (!appChannel.canPeerRom) {
              item.status = PeerItemStatus.skipped;
              item.error = '当前版本不允许导入游戏 ROM';
              report.skipped++;
              continue;
            }
            await _landRom(item, index, existingCrcs, existingPaths, progress);
            await _landCoverAndMeta(item.remote!, metadata);
          case PeerResourceKind.cheats:
            await _landCheats(item, cloudCheats);
          case PeerResourceKind.saveBattery:
          case PeerResourceKind.saveAuto:
          case PeerResourceKind.saveSlot:
            await _landSave(item, progress);
          case PeerResourceKind.bios:
            if (!appChannel.canPeerRom) {
              item.status = PeerItemStatus.skipped;
              item.error = '当前版本不允许导入系统文件';
              report.skipped++;
              break;
            }
            await _landBios(item, progress);
        }
        item.status = PeerItemStatus.done;
        item.error = null;
        report.bytes += item.remoteSize;
        if (wasOverwrite) {
          report.overwritten++;
        } else {
          report.added++;
        }
        // Persist JSON state after every item so a mid-transfer failure
        // never loses a completed import.
        await PeerFiles.atomicWriteJson(indexFile, index);
        await _persistByCrc('library/cloud_metadata.json', metadata);
        await _persistByCrc('library/cloud_cheats.json', cloudCheats);
      } catch (e) {
        item.status = PeerItemStatus.failed;
        item.error = '$e';
        report.failed++;
      }
    }

    return report;
  }

  // ----------------------------------------------------------- land helpers

  /// File name without its final extension (the archive/ROM suffix).
  String _stripExtension(String name) {
    final dot = name.lastIndexOf('.');
    return dot > 0 ? name.substring(0, dot) : name;
  }

  static final List<int> _crcTable = _buildCrcTable();
  static List<int> _buildCrcTable() {
    final t = List<int>.filled(256, 0);
    for (var n = 0; n < 256; n++) {
      var c = n;
      for (var k = 0; k < 8; k++) {
        c = (c & 1) != 0 ? (0xEDB88320 ^ (c >> 1)) : (c >> 1);
      }
      t[n] = c;
    }
    return t;
  }

  /// zlib/PNG CRC-32 of [f], streamed in 1 MiB chunks (fast, low memory).
  int _crc32OfFile(File f) {
    var crc = 0xFFFFFFFF;
    final raf = f.openSync();
    try {
      const chunkSize = 1 << 20;
      while (true) {
        final chunk = raf.readSync(chunkSize);
        if (chunk.isEmpty) break;
        for (var i = 0; i < chunk.length; i++) {
          crc = (crc >> 8) ^ _crcTable[(crc ^ chunk[i]) & 0xFF];
        }
        if (chunk.length < chunkSize) break;
      }
    } finally {
      raf.closeSync();
    }
    return (crc ^ 0xFFFFFFFF) & 0xFFFFFFFF;
  }

  /// Throws when [f]'s CRC-32 does not equal the advertised [crcHex] (8
  /// upper-hex). Guards every ROM transfer against truncation/corruption so a
  /// bad local copy is detectable and repairable. No-op when [crcHex] is
  /// missing/malformed (nothing to check against).
  void _verifyCrc(File f, String crcHex) {
    final want = int.tryParse(crcHex, radix: 16);
    if (want == null) return;
    final actual = _crc32OfFile(f);
    if (actual != (want & 0xFFFFFFFF)) {
      final hex = actual.toRadixString(16).padLeft(8, '0').toUpperCase();
      throw Exception('ROM 校验失败（数据不完整或已损坏）：期望 $crcHex，实际 $hex');
    }
  }

  /// Throws when [f]'s size does not equal the advertised [expected]. Used for
  /// resources without an advertised CRC (BIOS, saves, covers) as a
  /// completeness gate. No-op when [expected] <= 0.
  void _verifySize(File f, int expected, String label) {
    if (expected <= 0) return;
    final actual = f.lengthSync();
    if (actual != expected) {
      throw Exception('$label 不完整：期望 $expected 字节，实际 $actual');
    }
  }

  Future<void> _landRom(
    PeerPlanItem item,
    List<Map<String, dynamic>> index,
    Set<String> existingCrcs,
    Set<String> existingPaths,
    void Function(int, int?) progress,
  ) async {
    // Capability guard (mirrors the execute loop above). Unlike cloud ROM
    // fetch (canCloudRom, store-forbidden), this is a LAN-only partner copy.
    if (!appChannel.canPeerRom) return;
    final g = item.remote!;
    final platform = g.platform;
    final ext = CloudSyncer.extForPlatform(platform.toLowerCase());
    // Strip the archive extension from the title before re-appending [ext]:
    // the title is the original file name (e.g. `kof97.zip`), so naively
    // appending `.zip` produced the broken `kof97.zip.zip` that some cores
    // then refuse to load.
    final stem = _safeFileName(_stripExtension(g.title));

    // Force-replace an existing same-CRC ROM (repairs a corrupted/truncated
    // local copy). Otherwise a same-CRC local file is byte-identical, so there
    // is nothing to transfer.
    final overwrite = item.conflict && item.action == PeerItemAction.overwrite;
    if (existingCrcs.contains(item.crc) && !overwrite) return;

    // Locate the stale index record so an overwrite repairs it in place
    // (same CRC ⇒ same game) instead of orphaning a second copy.
    Map<String, dynamic>? stale;
    if (overwrite) {
      for (final e in index) {
        final v = ((e['crc32'] as num?)?.toInt() ?? 0) & 0xFFFFFFFF;
        if (v.toRadixString(16).padLeft(8, '0').toUpperCase() == item.crc) {
          stale = e;
          break;
        }
      }
    }

    var rel = 'roms/peer/$stem$ext';
    if (!overwrite) {
      var n = 2;
      // Guard against both index records and files already on disk (the index
      // can be rebuilt/missing while downloaded ROMs remain).
      while (existingPaths.contains(rel) ||
          File('$filesDir/$rel').existsSync()) {
        rel = 'roms/peer/$stem ($n)$ext';
        n++;
      }
    }

    final part = File('$filesDir/$rel.part');
    final dest = File('$filesDir/$rel');
    await dest.parent.create(recursive: true);
    try {
      await client.downloadRom(item.crc, part, onProgress: progress);
      // Integrity gate: reject a truncated/corrupt transfer before it can
      // replace (or sit beside) a good file. This is what makes a broken local
      // ROM repairable — the received bytes must hash to the advertised CRC.
      _verifyCrc(part, item.crc);
      await _replaceFile(part, dest);
    } catch (e) {
      await _deleteQuiet(part);
      if (!overwrite) await _deleteQuiet(dest);
      rethrow;
    }
    // An overwrite that also relocates the file (e.g. repairing the legacy
    // `kof97.zip.zip` path) removes the now-orphaned original.
    final staleRel = stale?['relativePath'] as String?;
    if (overwrite && staleRel != null && staleRel != rel) {
      await _deleteQuiet(File('$filesDir/$staleRel'));
    }

    final size = dest.lengthSync();
    final entry = <String, dynamic>{
      'name': '$stem$ext',
      'originalName': g.title,
      'relativePath': rel,
      'size': size,
      'crc32': int.parse(item.crc, radix: 16),
      'platform': platform == 'fds' ? 'nes' : platform,
      'importedAt': DateTime.now().toIso8601String(),
      'source': 'peer',
    };
    if (stale != null) {
      final at = index.indexOf(stale);
      if (at >= 0) {
        index[at] = entry;
      } else {
        index.add(entry);
      }
    } else {
      index.add(entry);
    }
    index.sort((a, b) => (a['name'] as String? ?? '')
        .toLowerCase()
        .compareTo((b['name'] as String? ?? '').toLowerCase()));
    existingCrcs.add(item.crc);
    existingPaths.add(rel);
  }

  Future<void> _landCoverAndMeta(
    RemoteGame g,
    Map<String, dynamic> metadata,
  ) async {
    final crc = g.crc;
    final meta = g.metadata;
    final bucket =
        (metadata.putIfAbsent(crc, () => <String, dynamic>{}) as Map)
            .cast<String, dynamic>();
    if (meta != null) {
      for (final k in _metaFields) {
        final v = meta[k];
        // Fill empty only: never overwrite fields already set on this device.
        if (bucket[k] is! String || (bucket[k] as String).trim().isEmpty) {
          if (v is String && v.trim().isNotEmpty) bucket[k] = v.trim();
        }
      }
    }
    if (g.hasCover) {
      final cover = File('$filesDir/library/covers-cloud/$crc.png');
      if (!cover.existsSync()) {
        final part = File('${cover.path}.part');
        await cover.parent.create(recursive: true);
        try {
          await client.downloadCover(crc, part);
          await _replaceFile(part, cover);
          bucket['cover'] = 'library/covers-cloud/$crc.png';
        } catch (e) {
          await _deleteQuiet(part);
          // Art is best-effort; missing cover must not fail the game.
        }
      } else {
        bucket.putIfAbsent('cover', () => 'library/covers-cloud/$crc.png');
      }
    }
  }

  Future<void> _landCheats(
    PeerPlanItem item,
    Map<String, dynamic> cloudCheats,
  ) async {
    // Always writes the CLOUD snapshot layer only; the player's local
    // cheats.json (with enabled/selected switches) is never touched.
    final res = await client.downloadCheats(item.crc);
    final cheats = res['cheats'];
    if (cheats is! List || cheats.isEmpty) return;
    cloudCheats[item.crc] = cheats;
  }

  Future<void> _landSave(
    PeerPlanItem item,
    void Function(int, int?) progress,
  ) async {
    final apiKind = item.saveApiKind!;
    final dest = File('$filesDir/${_saveRel(item.crc, apiKind)}');
    final part = File('${dest.path}.part');
    await dest.parent.create(recursive: true);
    try {
      await client.downloadSave(item.crc, apiKind, part,
          onProgress: progress);
      _verifySize(part, item.remoteSize, item.kindLabel);
      await _replaceFile(part, dest);
    } catch (e) {
      await _deleteQuiet(part);
      rethrow;
    }
    // Slot thumbnail rides along with the slot state.
    if (item.kind == PeerResourceKind.saveSlot) {
      RemoteSlot? thumb;
      for (final s in item.remote!.slots) {
        if (s.slot == item.slot) {
          thumb = s;
          break;
        }
      }
      if (thumb?.hasThumb == true) {
        final thumbFile =
            File('$filesDir/saves/${item.crc}.slot${item.slot}.jpg');
        final tpart = File('${thumbFile.path}.part');
        try {
          await client.downloadSave(
              item.crc, 'slotThumb${item.slot}', tpart);
          await _replaceFile(tpart, thumbFile);
        } catch (e) {
          await _deleteQuiet(tpart);
          rethrow;
        }
      }
    }
  }

  Future<void> _landBios(
    PeerPlanItem item,
    void Function(int, int?) progress,
  ) async {
    final name = item.title;
    final dest = File('$filesDir/system/$name');
    final part = File('${dest.path}.part');
    await dest.parent.create(recursive: true);
    try {
      await client.downloadBios(name, part, onProgress: progress);
      _verifySize(part, item.remoteSize, 'BIOS $name');
      await _replaceFile(part, dest);
    } catch (e) {
      await _deleteQuiet(part);
      if (item.action == PeerItemAction.add) await _deleteQuiet(dest);
      rethrow;
    }
    // Mirror into every location the installed cores read from (e.g. the
    // libretro MAME path `system/mame/roms`) so the imported games boot.
    await SystemFiles.syncToNeededLocations('$filesDir/system', name);
  }

  // ------------------------------------------------------- byCrc plumbing

  Map<String, dynamic> _loadByCrc(String rel) {
    final j = PeerFiles.readJsonOrNull(File('$filesDir/$rel'));
    if (j is Map && j['byCrc'] is Map) {
      return (j['byCrc'] as Map).cast<String, dynamic>();
    }
    return <String, dynamic>{};
  }

  Future<void> _persistByCrc(String rel, Map<String, dynamic> byCrc) =>
      PeerFiles.atomicWriteJson(
          File('$filesDir/$rel'), {'version': 1, 'byCrc': byCrc});

  /// Rename [part] onto [dest], deleting an existing [dest] first — plain
  /// `File.rename` refuses to overwrite on Windows and some platforms.
  Future<void> _replaceFile(File part, File dest) async {
    if (dest.existsSync()) dest.deleteSync();
    await part.rename(dest.path);
  }

  Future<void> _deleteQuiet(File f) async {
    try {
      if (f.existsSync()) f.deleteSync();
    } catch (_) {/* best effort */}
  }

  /// Convenience: plan + execute in one call for the standard UI flow.
  Future<PeerImportReport> run({
    required List<RemoteGame> games,
    required List<PeerGameSelection> selections,
    required Set<String> runningCrcs,
    required int? Function() availableBytes,
    void Function(PeerProgress)? onProgress,
  }) async {
    final plan = await buildPlan(
      games: games,
      selections: selections,
      runningCrcs: runningCrcs,
    );
    return execute(plan,
        availableBytes: availableBytes, onProgress: onProgress);
  }
}
