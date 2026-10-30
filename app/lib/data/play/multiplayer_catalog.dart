import 'dart:convert';

import 'package:flutter/services.dart';

/// How two players share the game.
enum MultiplayerMode {
  /// Simultaneous co-operation on the same screen (双人合作).
  coop,

  /// Head-to-head competition (双人对战).
  versus,

  /// Alternating turns (轮流上场, e.g. Super Mario Bros / Mappy / Circus
  /// Charlie on the Famicom).
  turn,
}

/// Built-in offline catalog deciding which games may be invited to a
/// netplay session.
///
/// Policy: **unknown means single player**. A game not present in this
/// catalog never gets a 「联机玩」 entry, and the signaling server rejects
/// direct invites for it (`not_multiplayer`), so hacked/unknown dumps are
/// closed by default.
///
/// Keys:
///   * `fceumm`       — uppercase CRC32 of the ROM (`RomEntry.crcKey`).
///   * `fbalpha2012`  — MAME/FBA driver name, i.e. the zip file stem,
///                      matched case-insensitively.
class MultiplayerCatalog {
  MultiplayerCatalog._(this._fceumm, this._fbalpha, this._mame);

  final Map<String, MultiplayerMode> _fceumm;
  final Map<String, MultiplayerMode> _fbalpha;
  final Map<String, MultiplayerMode> _mame;

  /// Catalog version from the asset (reserved for future migrations).
  static int get version => _version;
  static int _version = 0;

  /// Process-wide instance, populated during `main()` bootstrap. Code must
  /// tolerate null (unit tests, failed asset load): null fails closed, i.e.
  /// every game is treated as single player.
  static MultiplayerCatalog? instance;

  static const String assetPath = 'assets/data/multiplayer.json';

  static const _modeByName = {
    'coop': MultiplayerMode.coop,
    'versus': MultiplayerMode.versus,
    'turn': MultiplayerMode.turn,
  };

  /// Loads and caches the bundled catalog. Called once from `main()`.
  static Future<MultiplayerCatalog> loadAsset(
      {AssetBundle? bundle}) async {
    final b = bundle ?? rootBundle;
    final raw = await b.loadString(assetPath);
    final cat = parse(raw);
    instance = cat;
    return cat;
  }

  /// Visible for unit tests.
  static MultiplayerCatalog parse(String content) {
    final j = jsonDecode(content) as Map<String, dynamic>;
    final v = (j['version'] as num?)?.toInt() ?? 0;
    _version = v;
    return MultiplayerCatalog._(
      _parseSection(j['fceumm']),
      _parseSection(j['fbalpha2012'], lowercase: true),
      _parseSection(j['mame'], lowercase: true),
    );
  }

  static Map<String, MultiplayerMode> _parseSection(
    Object? raw, {
    bool lowercase = false,
  }) {
    final out = <String, MultiplayerMode>{};
    if (raw is Map) {
      raw.forEach((k, v) {
        final mode = _modeByName[v];
        if (k is String && mode != null) {
          out[lowercase ? k.toLowerCase() : k.toUpperCase()] = mode;
        }
      });
    }
    return out;
  }

  /// MAME/FBA driver name for an arcade zip file name (stem, lowercased).
  /// Examples: `Kof 97.zip` -> `kof 97`, `mslug3.zip` -> `mslug3`.
  ///
  /// The peer importer saves arcade ROMs as `<driver>.zip.zip` (it appends
  /// `.zip` to the partner's already-zipped name). Stripping a single
  /// extension left `kof97.zip`, which never matches the catalog driver
  /// `kof97` — so partner-imported games silently lost their 「联机玩」 entry
  /// (and failed the guest-side multiplayer gate). Keep stripping trailing
  /// archive extensions until the bare driver stem remains.
  static String driverFromFileName(String fileName) {
    var stem = fileName;
    final dot = stem.lastIndexOf('.');
    if (dot >= 0) stem = stem.substring(0, dot);
    while (true) {
      final lower = stem.toLowerCase();
      if (!lower.endsWith('.zip') && !lower.endsWith('.7z')) break;
      final d = stem.lastIndexOf('.');
      if (d <= 0) break;
      stem = stem.substring(0, d);
    }
    return stem.trim().toLowerCase();
  }

  /// Returns the multiplayer mode for a core/ROM pair, or null when the game
  /// is single-player / unknown.
  ///
  /// [romCrc] is required for `fceumm`; [driverName] (zip stem) for
  /// `fbalpha2012`. Passing both lets a future core set pick whichever key
  /// it uses.
  MultiplayerMode? modeFor({
    required String coreId,
    String? romCrc,
    String? driverName,
  }) {
    switch (coreId) {
      case 'fceumm':
        if (romCrc == null) return null;
        return _fceumm[romCrc.toUpperCase()];
      case 'fbalpha2012':
        if (driverName == null) return null;
        return _fbalpha[driverName.trim().toLowerCase()];
      case 'mame':
        if (driverName == null) return null;
        return _mame[driverName.trim().toLowerCase()];
      default:
        return null;
    }
  }

  bool isMultiplayer({
    required String coreId,
    String? romCrc,
    String? driverName,
  }) =>
      modeFor(
          coreId: coreId, romCrc: romCrc, driverName: driverName) !=
      null;

  /// Short Chinese badge label shown on game cards.
  static String labelOf(MultiplayerMode mode) {
    switch (mode) {
      case MultiplayerMode.coop:
        return '双人合作';
      case MultiplayerMode.versus:
        return '双人对战';
      case MultiplayerMode.turn:
        return '轮流上场';
    }
  }
}
