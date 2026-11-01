import 'package:flutter_test/flutter_test.dart';
import 'package:retroemupouch/features/membership/entitlement_service.dart';

void main() {
  Entitlement make({
    required MembershipTier tier,
    DateTime? trialStart,
    DateTime? expireAt,
    bool isLifetime = false,
  }) =>
      Entitlement(
        tier: tier,
        trialStart: trialStart,
        expireAt: expireAt,
        isLifetime: isLifetime,
      );

  group('Entitlement.isAdFree', () {
    test('free is ad-supported', () {
      expect(make(tier: MembershipTier.free).isAdFree, isFalse);
    });

    test('lifetime is ad-free', () {
      expect(make(tier: MembershipTier.lifetime, isLifetime: true).isAdFree,
          isTrue);
    });

    test('trial just started is ad-free (within 7 days)', () {
      // trialStart set to "now"; the getter checks now < trialStart + 7d.
      expect(make(tier: MembershipTier.trial, trialStart: DateTime.now()).isAdFree,
          isTrue);
    });

    test('trial past 7 days is ad-supported', () {
      final start = DateTime.now().subtract(const Duration(days: 8));
      final e = make(tier: MembershipTier.trial, trialStart: start);
      expect(e.isAdFree, isFalse);
      expect(e.effectiveTier, MembershipTier.free);
    });

    test('active monthly/yearly subscription is ad-free', () {
      final future = DateTime.now().add(const Duration(days: 10));
      expect(make(tier: MembershipTier.monthly, expireAt: future).isAdFree,
          isTrue);
      expect(make(tier: MembershipTier.yearly, expireAt: future).isAdFree,
          isTrue);
    });

    test('expired subscription is ad-supported', () {
      final past = DateTime.now().subtract(const Duration(days: 10));
      expect(make(tier: MembershipTier.monthly, expireAt: past).isAdFree,
          isFalse);
    });
  });

  group('Entitlement.cloudSaveEnabled', () {
    test('free/trial keep only local LAN sync', () {
      expect(make(tier: MembershipTier.free).cloudSaveEnabled, isFalse);
      expect(make(tier: MembershipTier.trial).cloudSaveEnabled, isFalse);
    });

    test('paid tiers unlock cloud save', () {
      expect(make(tier: MembershipTier.monthly).cloudSaveEnabled, isTrue);
      expect(make(tier: MembershipTier.yearly).cloudSaveEnabled, isTrue);
      expect(
          make(tier: MembershipTier.lifetime, isLifetime: true)
              .cloudSaveEnabled,
          isTrue);
    });
  });

  group('Entitlement.effectiveTier', () {
    test('active subscription keeps its tier', () {
      final future = DateTime.now().add(const Duration(days: 10));
      expect(make(tier: MembershipTier.yearly, expireAt: future).effectiveTier,
          MembershipTier.yearly);
    });

    test('lapsed subscription degrades to free', () {
      final past = DateTime.now().subtract(const Duration(days: 10));
      expect(make(tier: MembershipTier.yearly, expireAt: past).effectiveTier,
          MembershipTier.free);
    });
  });
}
