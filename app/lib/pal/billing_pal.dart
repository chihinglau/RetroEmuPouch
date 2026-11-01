import 'dart:async';

/// In-app purchase seam. Platform implementations slot in behind [createBillingPal]:
///   Android -> Google Play Billing
///   OHOS    -> Huawei IAP (IapKit)
///
/// [NoOpBillingPal] is the safe default until native billing lands.
abstract interface class BillingPal {
  /// Launch the purchase flow for [sku]. Returns true if the platform reported
  /// success (backend verification is still required before granting).
  Future<bool> purchase(String sku);

  /// Re-query previous purchases (e.g. after reinstall / on a new device).
  Future<bool> restore();
}

class NoOpBillingPal implements BillingPal {
  @override
  Future<bool> purchase(String sku) async {
    // TODO: Android Play Billing / OHOS Huawei IAP.
    return false;
  }

  @override
  Future<bool> restore() async => false;
}

BillingPal createBillingPal() => NoOpBillingPal();
