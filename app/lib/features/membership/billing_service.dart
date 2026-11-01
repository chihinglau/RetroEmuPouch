import 'dart:async';

import '../../pal/billing_pal.dart';
import 'entitlement_service.dart';
import 'receipt_verifier.dart';

/// Orchestrates purchases: calls [BillingPal], then verifies the receipt with the
/// [ReceiptVerifier] (backend authority) before granting entitlement. Falls back
/// to a local grant while no backend is wired, so the flow is exercisable
/// end-to-end against the NoOp pal/verifier.
class BillingService {
  BillingService(this._pal, this._entitlement, this._verifier);
  final BillingPal _pal;
  final EntitlementService _entitlement;
  final ReceiptVerifier _verifier;

  Future<bool> buy(MembershipTier tier) async {
    final sku = _skuFor(tier);
    if (sku.isEmpty) return false;
    final ok = await _pal.purchase(sku);
    if (!ok) return false;

    // Platform reported success. The authoritative entitlement comes from the
    // backend, not the client. Hand the receipt to the verifier...
    final verified = await _verifier.verifyPurchase(
      sku: sku,
      // TODO(server): obtain the real purchase token from the platform pal once
      // Play Billing / Huawei IAP is wired (BillingPal.purchase will surface it).
      token: '',
    );
    if (verified != null) {
      await _entitlement.grant(
        tier: verified.tier,
        expireAt: verified.expireAt,
        lifetime: verified.isLifetime,
      );
      return true;
    }

    // Backend unavailable (NoOp verifier): grant locally so the UI flow works.
    // TODO(server): remove this fallback once verifyPurchase is implemented; until
    // then a local grant is acceptable for pre-release testing only.
    final expireAt = switch (tier) {
      MembershipTier.monthly => DateTime.now().add(const Duration(days: 30)),
      MembershipTier.yearly => DateTime.now().add(const Duration(days: 365)),
      _ => null,
    };
    await _entitlement.grant(
      tier: tier,
      expireAt: expireAt,
      lifetime: tier == MembershipTier.lifetime,
    );
    return true;
  }

  Future<bool> restore() async {
    final verified = await _verifier.verifyRestore();
    if (verified != null) {
      await _entitlement.grant(
        tier: verified.tier,
        expireAt: verified.expireAt,
        lifetime: verified.isLifetime,
      );
      return true;
    }
    // No backend: just re-query the platform store for previous purchases.
    return _pal.restore();
  }

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
