import 'entitlement_service.dart';

/// Server-side receipt verification seam for in-app purchases.
///
/// The client can never be trusted with the truth of an entitlement: a purchase
/// token/receipt must be sent to the operator's backend, which checks it against
/// the store (Play Billing / Huawei IAP) and returns the *authoritative*
/// [Entitlement]. The client only caches the result (design doc §二.5/§二.7).
///
/// Until the backend exists this is a [NoOpReceiptVerifier] that returns `null`,
/// and [BillingService] falls back to a local grant so the purchase flow stays
/// exercisable end-to-end. Swap in a real implementation (HTTP call to the
/// operator's verify endpoint) without touching any call sites.
abstract interface class ReceiptVerifier {
  /// Verify a completed purchase. [sku] is the product id from [BillingService]
  /// (`premium_monthly` / `premium_yearly` / `premium_lifetime`); [token] is the
  /// opaque purchase token/receipt returned by the platform.
  /// Returns the authoritative entitlement, or `null` if verification is
  /// unavailable (e.g. NoOp backend) so the caller can decide on a fallback.
  Future<Entitlement?> verifyPurchase({
    required String sku,
    required String token,
  });

  /// Re-verify entitlements on reinstall / new device (maps to store "restore").
  Future<Entitlement?> verifyRestore();
}

/// Default no-backend implementation. Returns `null` so [BillingService] falls
/// back to its local grant. The real implementation performs:
///
/// ```text
/// POST /api/billing/verify  { sku, token }  ->  { tier, expireAt, isLifetime }
/// ```
///
/// TODO(server): implement the HTTP call and parse the authoritative entitlement.
class NoOpReceiptVerifier implements ReceiptVerifier {
  @override
  Future<Entitlement?> verifyPurchase({
    required String sku,
    required String token,
  }) async {
    // TODO(server): forward (sku, token) to backend; return its entitlement.
    return null;
  }

  @override
  Future<Entitlement?> verifyRestore() async {
    // TODO(server): query backend for the user's current entitlement.
    return null;
  }
}
