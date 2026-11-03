import 'package:flutter_test/flutter_test.dart';
import 'package:retroemupouch/features/membership/entitlement_service.dart';

/// 回归测试：横幅广告去除只看 [MembershipTier]，绝不读服务端 `is_lifetime` 布尔。
/// 普通VIP（含其终身档）必须保留横幅，只去开屏/插屏；只有超级VIP才去所有广告。
void main() {
  group('Entitlement.isAdFree（横幅去除只看 tier）', () {
    test('普通VIP终身：保留横幅，只去开屏/插屏', () {
      // 服务端对"终身时长"权益（含普通VIP终身）会回 is_lifetime=true，
      // 该布尔不得用于去横幅。
      final e = Entitlement(
        tier: MembershipTier.vipLifetime,
        isLifetime: true,
      );
      expect(e.isAdFree, isFalse); // 横幅仍展示
      expect(e.isVipActive, isTrue); // 去开屏/插屏
      expect(e.blocksInterstitialAds, isTrue);
    });

    test('普通VIP月付（未过期）：保留横幅', () {
      final e = Entitlement(
        tier: MembershipTier.vipMonthly,
        expireAt: DateTime.now().add(const Duration(days: 1)),
      );
      expect(e.isAdFree, isFalse);
      expect(e.isVipActive, isTrue);
    });

    test('普通VIP月付（已过期）：横幅与开屏都恢复', () {
      final e = Entitlement(
        tier: MembershipTier.vipMonthly,
        expireAt: DateTime.now().subtract(const Duration(days: 1)),
      );
      expect(e.isAdFree, isFalse);
      expect(e.isVipActive, isFalse);
      expect(e.blocksInterstitialAds, isFalse);
    });

    test('超级VIP终身：去所有广告（含横幅）', () {
      final e = Entitlement(tier: MembershipTier.lifetime, isLifetime: true);
      expect(e.isAdFree, isTrue);
      expect(e.blocksInterstitialAds, isTrue);
    });

    test('超级VIP月付（未过期）：去所有广告（含横幅）', () {
      final e = Entitlement(
        tier: MembershipTier.monthly,
        expireAt: DateTime.now().add(const Duration(days: 1)),
      );
      expect(e.isAdFree, isTrue);
    });

    test('试用窗内：去所有广告（含横幅）', () {
      final e = Entitlement(
        tier: MembershipTier.trial,
        trialStart: DateTime.now().subtract(const Duration(hours: 1)),
      );
      expect(e.isAdFree, isTrue);
    });

    test('免费：横幅与开屏都展示', () {
      const e = Entitlement(tier: MembershipTier.free);
      expect(e.isAdFree, isFalse);
      expect(e.blocksInterstitialAds, isFalse);
    });
  });
}
