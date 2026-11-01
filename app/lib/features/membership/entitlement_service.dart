import 'dart:async';

import 'package:shared_preferences/shared_preferences.dart';

/// Membership tiers. `trial` is the 7-day free trial granted on first sign-in.
enum MembershipTier { free, trial, monthly, yearly, lifetime }

extension MembershipTierX on MembershipTier {
  bool get isPaid =>
      this == MembershipTier.monthly ||
      this == MembershipTier.yearly ||
      this == MembershipTier.lifetime;

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
  MembershipTier get effectiveTier => isAdFree ? tier : MembershipTier.free;

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
class EntitlementService {
  EntitlementService._(this._prefs);
  static const trialDays = 7;

  final SharedPreferences _prefs;
  Entitlement _current = const Entitlement(tier: MembershipTier.free);
  Entitlement get current => _current;

  final _change = StreamController<Entitlement>.broadcast();
  Stream<Entitlement> get changes => _change.stream;

  static const _kTier = 'entitlement.tier';
  static const _kTrialStart = 'entitlement.trialStart';
  static const _kExpireAt = 'entitlement.expireAt';
  static const _kLifetime = 'entitlement.lifetime';

  static Future<EntitlementService> create() async {
    final prefs = await SharedPreferences.getInstance();
    final s = EntitlementService._(prefs);
    await s._load();
    return s;
  }

  Future<void> _load() async {
    _current = Entitlement(
      tier: _tierFromString(_prefs.getString(_kTier)),
      trialStart: _ms(_prefs.getInt(_kTrialStart)),
      expireAt: _ms(_prefs.getInt(_kExpireAt)),
      isLifetime: _prefs.getBool(_kLifetime) ?? false,
    );
    _emit();
  }

  /// 7-day trial begins on first sign-in. Idempotent.
  Future<void> ensureTrialStarted() async {
    if (_prefs.getInt(_kTrialStart) != null) return;
    final now = DateTime.now();
    await _prefs.setInt(_kTrialStart, now.millisecondsSinceEpoch);
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
    await _prefs.setString(_kTier, tier.name);
    if (expireAt != null) {
      await _prefs.setInt(_kExpireAt, expireAt.millisecondsSinceEpoch);
    }
    if (lifetime) await _prefs.setBool(_kLifetime, true);
    _current = _current.copyWith(
      tier: tier,
      expireAt: expireAt,
      isLifetime: lifetime,
    );
    _emit();
  }

  /// Test/debug helper: reset to free (does NOT refund real purchases).
  Future<void> reset() async {
    await _prefs.remove(_kTier);
    await _prefs.remove(_kTrialStart);
    await _prefs.remove(_kExpireAt);
    await _prefs.remove(_kLifetime);
    _current = const Entitlement(tier: MembershipTier.free);
    _emit();
  }

  int get trialRemainingDays {
    if (_current.trialStart == null) return trialDays;
    final end = _current.trialStart!.add(const Duration(days: trialDays));
    return end.difference(DateTime.now()).inDays.clamp(0, trialDays);
  }

  bool get isAdFree => _current.isAdFree;

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
