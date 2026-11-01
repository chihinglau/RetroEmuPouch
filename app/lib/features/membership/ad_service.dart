import 'package:flutter/widgets.dart';

import '../../pal/ad_pal.dart';
import 'entitlement_service.dart';

/// Drives ad display, gated by [EntitlementService.isAdFree] and a per-day cap
/// with a cooldown between shows. Safe when the underlying [AdPal] is the
/// [NoOpAdPal] (a non-intrusive test-placement placeholder, no real ad).
class AdService {
  AdService(this._pal, this._entitlement);
  final AdPal _pal;
  final EntitlementService _entitlement;

  int _shownToday = 0;
  String? _dayKey;
  DateTime? _lastShown;

  /// Daily cap (design doc §二.3: ≤3 次/日).
  static const maxPerDay = 3;
  /// Minimum gap between two interstitials, so a quick game-exit loop can't
  /// spam the user.
  static const cooldown = Duration(minutes: 1);

  /// Show an interstitial only when the user hasn't blocked interstitials
  /// (普通VIP already removes them), under the daily cap, and past the cooldown
  /// since the last one. Returns true if shown.
  Future<bool> maybeShowInterstitial() async {
    if (_entitlement.blocksInterstitialAds) return false;
    final now = DateTime.now();
    final dayKey = '${now.year}-${now.month}-${now.day}';
    if (_dayKey != dayKey) {
      _dayKey = dayKey;
      _shownToday = 0;
    }
    if (_shownToday >= maxPerDay) return false;
    if (_lastShown != null && now.difference(_lastShown!) < cooldown) {
      return false;
    }
    final shown = await _pal.showInterstitial();
    if (shown) {
      _shownToday++;
      _lastShown = DateTime.now();
    }
    return shown;
  }

  /// Banner widget to embed, or null when unsupported / ad-free.
  ///
  /// The OHOS [NoOpAdPal] test-placement placeholder is shown **regardless** of
  /// [EntitlementService.isAdFree] so the library layout can be validated on a
  /// test device (e.g. one whose trial made it ad-free) before Huawei/Petals
  /// ads are wired — once a real [AdPal] replaces [NoOpAdPal], the gate applies.
  Widget? bannerWidget() {
    if (_entitlement.isAdFree && _pal is! NoOpAdPal) return null;
    return _pal.bannerWidget();
  }
}
