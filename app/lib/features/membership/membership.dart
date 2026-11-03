import 'dart:async';

import 'package:flutter/foundation.dart' show kDebugMode;
import 'package:flutter/widgets.dart' show WidgetsBinding, WidgetsBindingObserver, AppLifecycleState;

import '../../pal/ad_pal.dart';
import 'ad_service.dart';
import '../../pal/billing_pal.dart';
import '../account/account_backend.dart'
    show createAccountBackend, kAccountBaseUrl, openAccountStore, AccountBackend;
import 'billing_service.dart';
import 'entitlement_service.dart';
import 'receipt_verifier.dart';

/// Lazily-initialised singleton bundling the membership subsystems so UI and
/// other services share one [EntitlementService] instance.
///
/// **会话 ↔ 权益 的唯一接线点（design-auth-membership-entitlement.md §3.3 / §5.3）**：
/// 订阅 [AccountBackend.authStateChanges] —— 登录时按账号拉取服务端权益、登出时清
/// 空；并在 App 回到前台（仅前台）时刷新，确保服务端过期/吊销自动反映到广告门控。
class Membership with WidgetsBindingObserver {
  Membership._(this.entitlement, this.ad, this.billing, this._account);

  final EntitlementService entitlement;
  final AdService ad;
  final BillingService billing;
  final AccountBackend _account;

  static Membership? _instance;

  static Future<Membership> get instance async {
    if (_instance != null) return _instance!;
    final e = await EntitlementService.create();
    // 联调（debug + 真实后端）下，用模拟成功的 pal + 后端 verify，让购买走真实后端。
    // 必须从 AccountStore（带鸿蒙文件兜底）读地址/token，不能裸读 SharedPreferences——
    // 鸿蒙上 getInstance() 抛异常返回 null，会使 realBackend 恒 false、mock 购买路径不激活，
    // 会员永远"购买未完成"。
    final store = await openAccountStore();
    final realBackend = (store.getString(kAccountBaseUrl) ?? '').trim().isNotEmpty;
    final useHttp = kDebugMode && realBackend;
    final pal = useHttp ? DebugSuccessBillingPal() : createBillingPal();
    final verifier =
        useHttp ? HttpReceiptVerifier(store) : NoOpReceiptVerifier();
    final account = await createAccountBackend();
    final billing = BillingService(
      pal,
      e,
      verifier,
      () => account.session != null,
    );
    final m = Membership._(
      e,
      AdService(createAdPal(), e),
      billing,
      account,
    );
    await m._wire();
    _instance = m;
    return _instance!;
  }

  Future<void> _wire() async {
    WidgetsBinding.instance.addObserver(this);
    _account.authStateChanges.listen((s) async {
      if (s == null) {
        await entitlement.clearActive();
      } else {
        await entitlement.setActiveUser(s.user.id);
        await billing.refresh();
      }
    });
  }

  /// App 回到前台（仅前台，绝不后台轮询）时刷新当前用户权益：服务端过期/吊销
  /// 会自动让 isAdFree 翻转为 false → 广告恢复。
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      final s = _account.session;
      if (s != null) {
        entitlement.setActiveUser(s.user.id);
        billing.refresh(); // 异步、fire-and-forget
      }
    }
  }
}
