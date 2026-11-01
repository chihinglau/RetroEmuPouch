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

/// Returns the platform-appropriate [BillingPal].
///
/// The real billing providers are wired in a later phase and require store-console
/// configuration + a backend receipt-verification endpoint (see design doc §二.5):
///   Android -> PlayBillingPal (`in_app_purchase` / `google_play_billing`),
///              SKUs `premium_monthly` / `premium_yearly` / `premium_lifetime`.
///   OHOS    -> HuaweiIapPal (IapKit), same SKU set; lifetime is a
///              non-consumable one-time SKU (§二.5).
/// [BillingService] hands the resulting token to [ReceiptVerifier] for the
/// authoritative grant. Until then the safe default keeps the app ad-supported
/// and never blocks the purchase flow.
BillingPal createBillingPal() {
  // TODO(platform): `if (Platform.operatingSystem == 'android') return PlayBillingPal();`
  //                 `if (Platform.operatingSystem == 'ohos') return HuaweiIapPal();`
  return NoOpBillingPal();
}
