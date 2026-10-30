import 'dart:io';

import '../../domain/rom_entry.dart';
import 'multiplayer_catalog.dart';

/// Virtual attribute-tag strings appended to library search haystacks.
///
/// The library/peer/cloud search boxes match `haystack.contains(query)`;
/// appending these Chinese tags lets users filter by attributes they could
/// otherwise not type (netplay whitelist, cheats, local save files) without
/// parsing the query or adding filter chips.
class LibrarySearch {
  const LibrarySearch._();

  /// Netplay/co-op/cheat/save tags for one entry, space joined. Returns an
  /// empty string when the entry has none of the attributes.
  static String attrTags({
    MultiplayerMode? mode,
    bool hasCheats = false,
    bool hasSave = false,
  }) {
    final tags = <String>[];
    if (mode != null) {
      // Generic words first so 「联机/多人/双人」 match every multiplayer
      // title; the specific mode label narrows to 合作/对战/轮流.
      tags.addAll(['联机玩', '联机', '多人', '双人', MultiplayerCatalog.labelOf(mode)]);
    }
    if (hasCheats) tags.addAll(['金手指', '作弊', '修改器']);
    if (hasSave) tags.addAll(['存档', '读档', '电池', '进度', '保存']);
    return tags.join(' ');
  }

  /// Multiplayer mode of a local [RomEntry] via the bundled catalog. Null
  /// when the catalog failed to load (fail-closed) or the core/ROM is not
  /// whitelisted.
  static MultiplayerMode? modeForRomEntry(MultiplayerCatalog? cat, RomEntry e) {
    final core = e.platform.coreId;
    if (cat == null || core == null) return null;
    return cat.modeFor(
      coreId: core,
      romCrc: e.crcKey,
      driverName: MultiplayerCatalog.driverFromFileName(e.driverFileName),
    );
  }

  /// Save keys present under `filesDir/saves/`.
  ///
  /// Console cores name saves by 8-hex CRC (EmulatorActivity saveKey):
  /// `<CRC>.sav` (non-empty), `<CRC>.state`, `<CRC>.slot<N>.state`; keys are
  /// uppercased. Arcade (fbalpha) cores name saves by zip stem/driver:
  /// `<driver>.state`, `<driver>.nv` (battery NVRAM), `<driver>.fs` (memory
  /// card); keys are lowercased and match
  /// [MultiplayerCatalog.driverFromFileName]. Thumbnails (`.jpg`),
  /// `.preplay` backups and zero-byte .sav files are ignored.
  /// Missing/erroring directories yield an empty set.
  static final RegExp _crcSave = RegExp(
      r'^([0-9A-F]{8})(?:\.sav|\.state|\.slot\d+\.state)$',
      caseSensitive: false);
  static final RegExp _namedSave = RegExp(
      r'^([0-9a-z_][0-9a-z_\- ]*?)(?:\.sav|\.state|\.slot\d+\.state|\.nv|\.fs)$',
      caseSensitive: false);

  static Set<String> scanSaveKeysSync(String filesDir) {
    final out = <String>{};
    final dir = Directory('$filesDir/saves');
    try {
      if (!dir.existsSync()) return out;
      for (final ent in dir.listSync(followLinks: false)) {
        if (ent is! File) continue;
        final base = ent.path.split(RegExp(r'[\\/]')).last;
        var m = _crcSave.firstMatch(base);
        if (m != null) {
          if (ent.path.endsWith('.sav')) {
            try {
              if (ent.lengthSync() <= 0) continue;
            } catch (_) {
              continue;
            }
          }
          out.add(m.group(1)!.toUpperCase());
          continue;
        }
        m = _namedSave.firstMatch(base);
        if (m == null) continue;
        if (ent.path.endsWith('.sav')) {
          try {
            if (ent.lengthSync() <= 0) continue;
          } catch (_) {
            continue;
          }
        }
        out.add(m.group(1)!.toLowerCase());
      }
    } catch (_) {
      // Unreadable saves dir: attribute search degrades to no save hits.
    }
    return out;
  }
}
