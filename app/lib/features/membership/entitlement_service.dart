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

  /// 服务端约定：试用期间 `tier` 保持 `free`，试用窗口只由 `trial_start` 判定
  /// （见后端 `Entitlement.is_trial_active`）。所以"free + 未过期 trial_start"
  /// 必须等价于 [MembershipTier.trial]，否则真机上试用用户会被显示成"免费用户"、
  /// 广告也不会被去掉。
  bool get trialActive =>
      tier == MembershipTier.free &&
      trialStart != null &&
      trialStart!
          .add(const Duration(days: EntitlementService.trialDays))
          .isAfter(DateTime.now());

  /// 去横幅广告？——**仅超级VIP（终身/月/年/试用）才去横幅**；普通VIP 任何档
  /// （含普通VIP终身）一律保留横幅。故本判定严格按 [tier] 驱动，**绝不读 `isLifetime`
  /// 布尔**——服务端对"终身时长"权益（含普通VIP终身）都会回 `is_lifetime:true`，
  /// 若拿来去横幅会让普通VIP终身误删横幅。开屏/插屏的去除走 [blocksInterstitialAds]。
  bool get isAdFree {
    if (trialActive) return true;
    final now = DateTime.now();
    switch (tier) {
      case MembershipTier.lifetime: // 超级VIP 买断
        return true;
      case MembershipTier.monthly:
      case MembershipTier.yearly: // 超级VIP 订阅（未过期）
        return expireAt != null && expireAt!.isAfter(now);
      case MembershipTier.trial: // 7 天试用窗内
        if (trialStart == null) return false;
        return trialStart!
            .add(const Duration(days: EntitlementService.trialDays))
            .isAfter(now);
      case MembershipTier.free:
      case MembershipTier.vipMonthly:
      case MembershipTier.vipYearly:
      case MembershipTier.vipLifetime: // 普通VIP：永远保留横幅
        return false;
    }
  }

  /// Tier to display: a lapsed trial/subscription degrades to [free].
  MembershipTier get effectiveTier {
    if (trialActive) return MembershipTier.trial;
    return isAdFree || isVipActive ? tier : MembershipTier.free;
  }

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

/// Owns the user's entitlement state.
///
/// **权益与账号绑定（design-auth-membership-entitlement.md §3.2）**：
/// 服务端是权益唯一真相源；本服务只按 `user_id` 缓存当前激活用户的权益。
/// 无激活用户（未登录）即 [free]。订阅 [authStateChanges] 的模块调用
/// [setActiveUser] / [clearActive] 完成"登录取、登出清"的联动。
///
/// Persistence follows the same ladder as `AppSettings`: shared_preferences
/// first, and when it has no native handler (OHOS → `MissingPluginException`),
/// a PlatformPal file store wired via [setFallbackStore].
class EntitlementService {
  EntitlementService._(this._prefs);
  static const trialDays = 7;

  /// Null when shared_preferences is unavailable (OHOS) — the file fallback
  /// store below takes over.
  final SharedPreferences? _prefs;

  /// 激活用户的 `user_id`；null 表示未登录（权益回落免费）。
  String? _activeUserId;

  /// Authoritative in-memory KV (prefixed by user, e.g. `entitlement.u123.tier`),
  /// mirrored to whichever store (prefs or file fallback) is available.
  final Map<String, Object> _kv = {};

  Entitlement _current = const Entitlement(tier: MembershipTier.free);
  Entitlement get current => _current;

  final _change = StreamController<Entitlement>.broadcast();
  Stream<Entitlement> get changes => _change.stream;

  static const _kPrefix = 'entitlement.';
  static const _kTier = 'tier';
  static const _kTrialStart = 'trialStart';
  static const _kExpireAt = 'expireAt';
  static const _kLifetime = 'lifetime';

  /// 遗留设备级扁平键（升级迁移时清除）。
  static const _legacyKeys = [
    'entitlement.tier',
    'entitlement.trialStart',
    'entitlement.expireAt',
    'entitlement.lifetime',
  ];

  String? get _prefix =>
      _activeUserId == null ? null : '$_kPrefix$_activeUserId.';

  // ---- PlatformPal file-store fallback (shared_preferences-less platforms) --
  // Wired by main() from the active PlatformPal so entitlements persist on
  // OHOS, where shared_preferences has no native handler.
  static Future<Map<String, Object>?> Function()? _fallbackLoad;
  static Future<void> Function(Map<String, Object>) ? _fallbackSave;

  static void setFallbackStore({
    required Future<Map<String, Object>?> Function() load,
    required Future<void> Function(Map<String, Object>) save,
  }) {
    _fallbackLoad = load;
    _fallbackSave = save;
  }

  static Future<EntitlementService> create() async {
    // getInstance() throws MissingPluginException on OHOS (no native handler);
    // fall back to the PlatformPal file store instead of rejecting upward.
    SharedPreferences? prefs;
    try {
      prefs = await SharedPreferences.getInstance();
    } catch (_) {
      prefs = null;
    }
    final s = EntitlementService._(prefs);
    // 迁移：清除遗留设备级扁平键，改为按 user_id 存储。
    if (prefs != null) {
      for (final k in _legacyKeys) {
        try {
          await prefs.remove(k);
        } catch (_) {
          // 忽略单个键删除失败。
        }
      }
    }
    // 不在此加载任何用户：激活用户由订阅 authStateChanges 的模块设置。
    s._current = const Entitlement(tier: MembershipTier.free);
    s._emit();
    return s;
  }

  /// 切换到指定用户：加载其磁盘缓存并设为当前权益。未登录态调用前务必先 [clearActive]。
  Future<void> setActiveUser(String userId) async {
    _activeUserId = userId;
    _kv.clear();
    final p = _prefs;
    if (p != null) {
      final pre = '$_kPrefix$userId.';
      try {
        final t = p.getString('${pre}$_kTier');
        final ts = p.getInt('${pre}$_kTrialStart');
        final ex = p.getInt('${pre}$_kExpireAt');
        final lf = p.getBool('${pre}$_kLifetime');
        if (t != null) _kv['${pre}$_kTier'] = t;
        if (ts != null) _kv['${pre}$_kTrialStart'] = ts;
        if (ex != null) _kv['${pre}$_kExpireAt'] = ex;
        if (lf != null) _kv['${pre}$_kLifetime'] = lf;
      } catch (_) {
        // prefs 读取中途失败：回退到文件存储。
      }
    }
    if (_kv.isEmpty) {
      try {
        final m = await _fallbackLoad?.call();
        if (m != null) {
          final pre = '$_kPrefix$userId.';
          for (final k in m.keys) {
            if (k.startsWith(pre)) _kv[k] = m[k]!;
          }
        }
      } catch (_) {
        // 无回退存储：保持默认。
      }
    }
    _rebuild();
  }

  /// 登出 / 注销：清除激活用户，权益回落免费（不删除各用户的磁盘缓存，供离线/快速恢复）。
  Future<void> clearActive() async {
    _activeUserId = null;
    _kv.clear();
    _rebuild();
  }

  /// 单一写路径：更新内存 KV（按当前激活用户前缀），再持久化。
  /// 无激活用户时不持久化（避免写入遗留扁平键）。
  Future<void> _set(String field, Object? value) async {
    final pre = _prefix;
    if (pre == null) return;
    final key = '$pre$field';
    if (value == null) {
      _kv.remove(key);
    } else {
      _kv[key] = value;
    }
    await _persist();
    _rebuild();
  }

  Future<void> _persist() async {
    final p = _prefs;
    if (p != null) {
      try {
        for (final e in _kv.entries) {
          final k = e.key;
          final v = e.value;
          if (v is String) {
            await p.setString(k, v);
          } else if (v is int) {
            await p.setInt(k, v);
          } else if (v is bool) {
            await p.setBool(k, v);
          }
        }
        return;
      } catch (_) {
        // prefs 不可用/失败：走文件存储。
      }
    }
    try {
      final existing = await _fallbackLoad?.call() ?? <String, Object>{};
      final pre = _prefix;
      if (pre != null) existing.removeWhere((k, _) => k.startsWith(pre));
      existing.addAll(_kv);
      await _fallbackSave?.call(existing);
    } catch (_) {
      // Best-effort：本会话仅留在内存。
    }
  }

  void _rebuild() {
    final pre = _prefix;
    Entitlement e = const Entitlement(tier: MembershipTier.free);
    if (pre != null) {
      e = Entitlement(
        tier: _tierFromString(_kv['$pre$_kTier'] as String?),
        trialStart: _ms(_kv['$pre$_kTrialStart'] as int?),
        expireAt: _ms(_kv['$pre$_kExpireAt'] as int?),
        isLifetime: (_kv['$pre$_kLifetime'] as bool?) ?? false,
      );
    }
    _current = e;
    _emit();
  }

  /// 7 天试用（乐观本地写入；服务端权威见 [Membership] 在登录时调 trial/start）。
  /// 仅在已登录（有激活用户）时生效。
  Future<void> ensureTrialStarted() async {
    final pre = _prefix;
    if (pre == null) return; // 未登录不开启试用
    if (_kv.containsKey('$pre$_kTrialStart')) return;
    final now = DateTime.now();
    await _set(_kTrialStart, now.millisecondsSinceEpoch);
  }

  /// 服务端权益落地：由 [BillingService] 在校验通过后调用，写入当前激活用户。
  /// 替代原有"本地授予"，客户端只缓存服务端结论。
  Future<void> applyServer(Entitlement e) async {
    await _set(_kTier, e.tier.name);
    await _set(_kExpireAt, e.expireAt?.millisecondsSinceEpoch);
    await _set(_kTrialStart, e.trialStart?.millisecondsSinceEpoch);
    if (e.isLifetime) await _set(_kLifetime, true);
  }

  /// 测试/调试辅助：清除当前激活用户的权益（不退还真实购买）。
  Future<void> reset() async {
    await _set(_kTier, null);
    await _set(_kTrialStart, null);
    await _set(_kExpireAt, null);
    await _set(_kLifetime, null);
  }

  int get trialRemainingDays {
    if (_current.trialStart == null) return trialDays;
    final end = _current.trialStart!.add(const Duration(days: trialDays));
    final left = end.difference(DateTime.now());
    if (left.isNegative) return 0;
    // 向上取整：刚开启时应显示"剩余 7 天"，而不是 floor 出来的 6 天。
    return (left.inMinutes / Duration.minutesPerDay).ceil().clamp(0, trialDays);
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
