import 'dart:async';

import '../../pal/ad_pal.dart';
import 'ad_service.dart';
import '../../pal/billing_pal.dart';
import 'billing_service.dart';
import 'entitlement_service.dart';

/// Lazily-initialised singleton bundling the membership subsystems so UI and
/// other services share one [EntitlementService] instance.
class Membership {
  Membership._(this.entitlement, this.ad, this.billing);

  final EntitlementService entitlement;
  final AdService ad;
  final BillingService billing;

  static Membership? _instance;

  static Future<Membership> get instance async {
    if (_instance != null) return _instance!;
    final e = await EntitlementService.create();
    _instance = Membership._(
      e,
      AdService(createAdPal(), e),
      BillingService(createBillingPal(), e),
    );
    return _instance!;
  }
}
