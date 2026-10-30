import '../../domain/rom_entry.dart';
import 'play_session.dart';

/// Static capability/gating table for the netplay MVP.
///
/// Only cores whose cross-device determinism has been verified (Phase 0 +
/// Task 8) may be invited. Everything else must not even render an entry.
class NetplayCapability {
  const NetplayCapability._();

  /// libretro core ids allowed for netplay (must match native core .so ids).
  /// 'mame' is the store-channel arcade core; 'fbalpha2012' the community one.
  static const Set<String> supportedCores = {'fbalpha2012', 'fceumm', 'mame'};

  /// MVP is strictly 2 players.
  static const int maxPlayers = 2;

  /// Native packet protocol version, exchanged in the invite envelope.
  static const int protoVersion = PlayProtocol.netplayProtoVersion;

  /// Invite validity window; mirrored by [PlaySessionManager.inviteTtl].
  static const int inviteTtlSec = 60;

  /// Maps a partner-library `platform` tag ('nes' / 'mame' / 'neogeo') to
  /// the libretro core id the local runner would use for it. Returns null
  /// when the platform is unknown to this build.
  static String? coreForPlatform(String platformName) {
    for (final p in PlatformKind.values) {
      if (p.name == platformName) return p.coreId;
    }
    return null;
  }

  /// Stable machine-readable rejection codes.
  static const String rejectNotPaired = 'not_paired';
  static const String rejectVersionMismatch = 'version_mismatch';
  static const String rejectRomNotLocal = 'rom_not_local';
  static const String rejectCoreUnsupported = 'core_unsupported';

  /// The game is a single-player / unknown title per the built-in
  /// [MultiplayerCatalog]. Only games that genuinely support two players
  /// may be invited; hacks and dumps outside the catalog fail closed.
  static const String rejectNotMultiplayer = 'not_multiplayer';

  /// Cross-device determinism gate (skills.md §871): the partner's core id
  /// differs from the local one (e.g. MAME vs FBA) — serialized state can
  /// never match, so netplay would desync on frame 0.
  static const String rejectCoreMismatch = 'core_mismatch';

  /// The partner's ROM CRC32 differs from the local copy — not the same
  /// dump, so emulation diverges immediately.
  static const String rejectRomMismatch = 'rom_mismatch';

  /// The partner's BIOS CRC (e.g. neogeo.zip for MAME/NeoGeo) differs from
  /// the local one — the machine boots from a different BIOS, desyncing
  /// from frame 0 even when the ROM and core id match.
  static const String rejectBiosMismatch = 'bios_mismatch';

  /// Returns null when an invite is allowed, otherwise one of the
  /// `reject*` codes above.
  ///
  /// [sameVersion] is the best pre-invite knowledge the UI has (partner
  /// /info versionName vs local). The authoritative versionCode gate still
  /// runs server-side in [PlaySessionManager.handleInvite].
  ///
  /// [isMultiplayer] is the catalog lookup. Defaults true so legacy call
  /// sites that only reason about core ownership keep compiling; the peer
  /// library always passes the catalog result explicitly.
  static String? rejectReason({
    required String? coreId,
    required bool localOwned,
    required bool sameVersion,
    required bool paired,
    bool isMultiplayer = true,
  }) {
    if (!paired) return rejectNotPaired;
    if (!sameVersion) return rejectVersionMismatch;
    if (!localOwned) return rejectRomNotLocal;
    if (coreId == null || !supportedCores.contains(coreId)) {
      return rejectCoreUnsupported;
    }
    if (!isMultiplayer) return rejectNotMultiplayer;
    return null;
  }

  /// Convenience boolean wrapper.
  static bool canInvite({
    required String? coreId,
    required bool localOwned,
    required bool sameVersion,
    required bool paired,
    bool isMultiplayer = true,
  }) =>
      rejectReason(
        coreId: coreId,
        localOwned: localOwned,
        sameVersion: sameVersion,
        paired: paired,
        isMultiplayer: isMultiplayer,
      ) ==
      null;

  /// Cross-device determinism gate (skills.md §871). Compares the partner's
  /// core / ROM / BIOS fingerprint against the local one and returns a stable
  /// reject code, or null when they match.
  ///
  /// Call this from the invite UI with the *remote* game's identity
  /// (carried in the partner library / invite envelope) and the *local*
  /// game's identity. [biosCrc] may be null on either side for cores that
  /// need no BIOS (e.g. NES); a present-vs-null mismatch is still reported
  /// because it means one side is missing a BIOS the other requires.
  static String? crossDeviceReject({
    required String? remoteCoreId,
    required String? localCoreId,
    required String? remoteRomCrc,
    required String? localRomCrc,
    String? remoteBiosCrc,
    String? localBiosCrc,
  }) {
    if (remoteCoreId != null &&
        localCoreId != null &&
        remoteCoreId != localCoreId) {
      return rejectCoreMismatch;
    }
    if (remoteRomCrc != null &&
        localRomCrc != null &&
        remoteRomCrc.toUpperCase() != localRomCrc.toUpperCase()) {
      return rejectRomMismatch;
    }
    if (remoteBiosCrc != null &&
        localBiosCrc != null &&
        remoteBiosCrc.toUpperCase() != localBiosCrc.toUpperCase()) {
      return rejectBiosMismatch;
    }
    return null;
  }

  /// User-facing Chinese text for a [rejectReason] code (used in subtitles /
  /// snackbars; deliberately terse, no popups).
  static String reasonText(String code) {
    switch (code) {
      case rejectNotPaired:
        return '需要先完成伙伴配对';
      case rejectVersionMismatch:
        return '双方趣玩匣版本需一致，请先升级到同一版本';
      case rejectRomNotLocal:
        return '本机还没有这款游戏，先导入后再联机';
      case rejectCoreUnsupported:
        return '该游戏的模拟器核心暂不支持联机（本期支持街机 FBA / MAME 与 FC）';
      case rejectNotMultiplayer:
        return '该游戏为单人游戏，不支持联机';
      case rejectCoreMismatch:
        return '双方模拟器核心不一致（如 MAME 与 FBA），无法联机';
      case rejectRomMismatch:
        return '双方游戏 ROM 版本不一致，请导入相同的 ROM 后重试';
      case rejectBiosMismatch:
        return '双方 BIOS 不一致（如 neogeo.zip 不同），请先同步 BIOS 再联机';
      default:
        return '当前不满足联机条件';
    }
  }
}
