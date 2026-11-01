import 'dart:async';

import 'package:shared_preferences/shared_preferences.dart';

/// Membership tiers. `trial` is the 7-day free trial granted on first sign-in.
/// The `vip*` group is the 普通VIP level (interstitial/splash ads removed but
/// the banner kept); the plain monthly/yearly/lifetime group is 超级VIP
/// (everything removed). Prices live in the store, not here.
enum MembershipTier {
  free,
  trial,
  monthly,
  yearly,
  lifetime,
  vipMonthly,
  vipYearly,
  vipLifetime,
}

extension MembershipTierX on MembershipTier {
  bool get isPaid =>
      this == MembershipTier.monthly ||
      this == MembershipTier.yearly ||
      this == MembershipTier.lifetime ||
      this == MembershipTier.vipMonthly ||
      this == MembershipTier.vipYearly ||
      this == MembershipTier.vipLifetime;

  /// 普通VIP billing periods (banner-keeping level).
  bool get isVipPlan =>
      this == MembershipTier.vipMonthly ||
      this == MembershipTier.vipYearly ||
      this == MembershipTier.vipLifetime;

  String get label {
    switch (this) {
      case MembershipTier.free:
        return '免费';
      case MembershipTier.trial:
        return '试用';
      case MembershipTier.monthly:
        return '月会员';
      case MembershipTier.yearly:
        return '年会员';
      case MembershipTier.lifetime:
        return '终身会员';
      case MembershipTier.vipMonthly:
        return '普通VIP·月付';
      case MembershipTier.vipYearly:
        return '普通VIP·年付';
      case MembershipTier.vipLifetime:
        return '普通VIP·终身';
    }
  }
}

/// Snapshot of a user's current entitlement (local cache; server is authoritative).
class Entitlement {
  const Entitlement({
    required this.tier,
    this.trialStart,
    this.expireAt,
    this.isLifetime = false,
  });

  final MembershipTier tier;
  final DateTime? trialStart;
  final DateTime? expireAt;
  final bool isLifetime;

  /// Ad-free when: lifetime, or an active (non-expired) subscription, or within
  /// the 7-day trial window.
  bool get isAdFree {
    if (isLifetime || tier == MembershipTier.lifetime) return true;
    final now = DateTime.now();
    if (tier == MembershipTier.monthly || tier == MembershipTier.yearly) {
      return expireAt != null && expireAt!.isAfter(now);
    }
    if (tier == MembershipTier.trial) {
      if (trialStart == null) return false;
      return trialStart!
          .add(const Duration(days: EntitlementService.trialDays))
          .isAfter(now);
    }
    return false;
  }

  /// Tier to display: a lapsed trial/subscription degrades to [free].
  MembershipTier get effectiveTier =>
      isAdFree || isVipActive ? tier : MembershipTier.free;

  /// 普通VIP level active (non-expired): removes interstitial/splash ads but
  /// keeps the banner. Lifetime (买断) never expires.
  bool get isVipActive {
    if (!tier.isVipPlan) return false;
    if (tier == MembershipTier.vipLifetime || isLifetime) return true;
    final now = DateTime.now();
    return expireAt != null && expireAt!.isAfter(now);
  }

  /// True when interstitial/splash ads must not be shown: full ad-free
  /// (超级VIP / trial / lifetime) or the 普通VIP level. The banner keeps showing
  /// for 普通VIP — gate that on [isAdFree] only.
  bool get blocksInterstitialAds => isAdFree || isVipActive;

  /// Cloud-save benefit (design doc §二.4): paid tiers unlock enhanced,
  /// server-backed save sync (more slots / larger backups). Free and trial users
  /// keep only local LAN sync via their own PC. Drives UI copy + (later) the
  /// server-side quota check; it never gates the local sync itself.
  bool get cloudSaveEnabled => tier.isPaid;

  Entitlement copyWith({
    MembershipTier? tier,
    DateTime? trialStart,
    DateTime? expireAt,
    bool? isLifetime,
  }) =>
      Entitlement(
        tier: tier ?? this.tier,
        trialStart: trialStart ?? this.trialStart,
        expireAt: expireAt ?? this.expireAt,
        isLifetime: isLifetime ?? this.isLifetime,
      );
}

/// Owns the user's entitlement state, persisted locally and refreshed from the
/// backend in a later phase. Exposes [isAdFree] used to gate ads and the
/// 7-day trial lifecycle ([ensureTrialStarted]).
///
/// Persistence follows the same ladder as `AppSettings`: shared_preferences
/// first, and when it has no native handler (OHOS → `MissingPluginException`),
/// a PlatformPal file store wired via [setFallbackStore]. Without this ladder
/// `Membership.instance` would reject on OHOS and every membership UI would
/// hang on its loading spinner.
class EntitlementService {
  EntitlementService._(this._prefs);
  static const trialDays = 7;

  /// Null when shared_preferences is unavailable (OHOS) — the file fallback
  /// store below takes over.
  final SharedPreferences? _prefs;

  /// Authoritative in-memory key-value state, mirrored to whichever store
  /// (prefs or file fallback) is available.
  final Map<String, Object> _kv = {};

  Entitlement _current = const Entitlement(tier: MembershipTier.free);
  Entitlement get current => _current;

  final _change = StreamController<Entitlement>.broadcast();
  Stream<Entitlement> get changes => _change.stream;

  static const _kTier = 'entitlement.tier';
  static const _kTrialStart = 'entitlement.trialStart';
  static const _kExpireAt = 'entitlement.expireAt';
  static const _kLifetime = 'entitlement.lifetime';

  // ---- PlatformPal file-store fallback (shared_preferences-less platforms) --
  // Wired by main() from the active PlatformPal so entitlements persist on
  // OHOS, where shared_preferences has no native handler.
  static Future<Map<String, Object>?> Function()? _fallbackLoad;
  static Future<void> Function(Map<String, Object>)? _fallbackSave;

  static void setFallbackStore({
    required Future<Map<String, Object>?> Function() load,
    required Future<void> Function(Map<String, Object>) save,
  }) {
    _fallbackLoad = load;
    _fallbackSave = save;
  }

  static Future<EntitlementService> create() async {
    // getInstance() throws MissingPluginException on OHOS (no native handler);
    // fall back to the PlatformPal file store instead of rejecting upward —
    // an unhandled rejection here left the membership page on its spinner.
    SharedPreferences? prefs;
    try {
      prefs = await SharedPreferences.getInstance();
    } catch (_) {
      prefs = null;
    }
    final s = EntitlementService._(prefs);
    await s._load();
    return s;
  }

  Future<void> _load() async {
    final p = _prefs;
    if (p != null) {
      try {
        final tier = p.getString(_kTier);
        final trialStart = p.getInt(_kTrialStart);
        final expireAt = p.getInt(_kExpireAt);
        final lifetime = p.getBool(_kLifetime);
        if (tier != null) _kv[_kTier] = tier;
        if (trialStart != null) _kv[_kTrialStart] = trialStart;
        if (expireAt != null) _kv[_kExpireAt] = expireAt;
        if (lifetime != null) _kv[_kLifetime] = lifetime;
      } catch (_) {
        // prefs read failed mid-way: fall through to the file store below.
      }
    }
    if (_kv.isEmpty) {
      try {
        final m = await _fallbackLoad?.call();
        if (m != null) _kv.addAll(m);
      } catch (_) {
        // No fallback store either: defaults stand.
      }
    }
    _current = Entitlement(
      tier: _tierFromString(_kv[_kTier] as String?),
      trialStart: _ms(_kv[_kTrialStart] as int?),
      expireAt: _ms(_kv[_kExpireAt] as int?),
      isLifetime: (_kv[_kLifetime] as bool?) ?? false,
    );
    _emit();
  }

  /// Single write path: updates the in-memory KV, then persists through
  /// shared_preferences when available, else the file-store fallback.
  Future<void> _set(String key, Object? value) async {
    if (value == null) {
      _kv.remove(key);
    } else {
      _kv[key] = value;
    }
    final p = _prefs;
    if (p != null) {
      try {
        if (value == null) {
          await p.remove(key);
        } else if (value is String) {
          await p.setString(key, value);
        } else if (value is int) {
          await p.setInt(key, value);
        } else if (value is bool) {
          await p.setBool(key, value);
        }
        return;
      } catch (_) {
        // prefs unavailable/failed: persist via the file store below.
      }
    }
    try {
      await _fallbackSave?.call(Map<String, Object>.of(_kv));
    } catch (_) {
      // Best-effort: state stays in memory this session.
    }
  }

  /// 7-day trial begins on first sign-in. Idempotent.
  Future<void> ensureTrialStarted() async {
    if (_kv.containsKey(_kTrialStart)) return;
    final now = DateTime.now();
    await _set(_kTrialStart, now.millisecondsSinceEpoch);
    _current = _current.copyWith(tier: MembershipTier.trial, trialStart: now);
    _emit();
  }

  /// Called by [BillingService] after the backend verifies a purchase.
  /// TODO(server): replace local grant with server-verified entitlement.
  Future<void> grant({
    required MembershipTier tier,
    DateTime? expireAt,
    bool lifetime = false,
  }) async {
    await _set(_kTier, tier.name);
    await _set(_kExpireAt, expireAt?.millisecondsSinceEpoch);
    if (lifetime) await _set(_kLifetime, true);
    _current = _current.copyWith(
      tier: tier,
      expireAt: expireAt,
      isLifetime: lifetime,
    );
    _emit();
  }

  /// Test/debug helper: reset to free (does NOT refund real purchases).
  Future<void> reset() async {
    await _set(_kTier, null);
    await _set(_kTrialStart, null);
    await _set(_kExpireAt, null);
    await _set(_kLifetime, null);
    _current = const Entitlement(tier: MembershipTier.free);
    _emit();
  }

  int get trialRemainingDays {
    if (_current.trialStart == null) return trialDays;
    final end = _current.trialStart!.add(const Duration(days: trialDays));
    return end.difference(DateTime.now()).inDays.clamp(0, trialDays);
  }

  bool get isAdFree => _current.isAdFree;

  /// 普通VIP 档生效中（去插屏、留横幅）。
  bool get isVipActive => _current.isVipActive;

  /// 插屏/开屏广告是否被移除（超级档、试用或普通VIP）。
  bool get blocksInterstitialAds => _current.blocksInterstitialAds;

  void _emit() => _change.add(_current);

  static DateTime? _ms(int? v) =>
      v == null ? null : DateTime.fromMillisecondsSinceEpoch(v);

  static MembershipTier _tierFromString(String? v) {
    if (v == null) return MembershipTier.free;
    return MembershipTier.values.firstWhere(
      (e) => e.name == v,
      orElse: () => MembershipTier.free,
    );
  }
}
