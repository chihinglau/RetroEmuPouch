import 'dart:async';

import '../../pal/billing_pal.dart';
import 'entitlement_service.dart';

/// Orchestrates purchases: calls [BillingPal], then (after backend
/// verification) grants entitlement via [EntitlementService].
class BillingService {
  BillingService(this._pal, this._entitlement);
  final BillingPal _pal;
  final EntitlementService _entitlement;

  Future<bool> buy(MembershipTier tier) async {
    final sku = _skuFor(tier);
    if (sku.isEmpty) return false;
    final ok = await _pal.purchase(sku);
    if (!ok) return false;
    // TODO(server): send purchaseToken to backend for verification, await the
    // authoritative entitlement, then grant. For now grant locally so the flow
    // is exercisable end-to-end against the NoOp pal.
    final expireAt = switch (tier) {
      MembershipTier.monthly =>
        DateTime.now().add(const Duration(days: 30)),
      MembershipTier.yearly =>
        DateTime.now().add(const Duration(days: 365)),
      _ => null,
    };
    await _entitlement.grant(
      tier: tier,
      expireAt: expireAt,
      lifetime: tier == MembershipTier.lifetime,
    );
    return true;
  }

  Future<bool> restore() async => _pal.restore();

  static String _skuFor(MembershipTier t) {
    switch (t) {
      case MembershipTier.monthly:
        return 'premium_monthly';
      case MembershipTier.yearly:
        return 'premium_yearly';
      case MembershipTier.lifetime:
        return 'premium_lifetime';
      default:
        return '';
    }
  }
}
