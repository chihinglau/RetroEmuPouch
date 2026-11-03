import '../../pal/billing_pal.dart';
import 'entitlement_service.dart';
import 'receipt_verifier.dart';

/// Orchestrates purchases: calls [BillingPal], then verifies the receipt with the
/// [ReceiptVerifier] (backend authority) before applying entitlement.
///
/// 安全契约（design-auth-membership-entitlement.md §3.5）：客户端**绝不**自行决定
/// 权益真相。校验通过前不授予；release 下无任何本地兜底授予。未登录（无会话）
/// 直接拒绝，避免"无账号本地发会员"的无效操作。
class BillingService {
  BillingService(
    this._pal,
    this._entitlement,
    this._verifier,
    this._isSignedIn,
  );
  final BillingPal _pal;
  final EntitlementService _entitlement;
  final ReceiptVerifier _verifier;
  final bool Function() _isSignedIn;

  Future<bool> buy(MembershipTier tier) async {
    if (!_isSignedIn()) return false;
    final sku = _skuFor(tier);
    if (sku.isEmpty) return false;
    final ok = await _pal.purchase(sku);
    if (!ok) return false;

    // 平台报告成功：权威权益来自后端校验结果，而非客户端。
    final verified = await _verifier.verifyPurchase(
      sku: sku,
      // TODO(server): 接入 Play Billing / Huawei IAP 后由 BillingPal.purchase
      // 透出真实 purchase token。
      token: '',
    );
    if (verified != null) {
      await _entitlement.applyServer(verified);
      return true;
    }
    // 后端不可达 / 未校验通过：不再本地兜底授予。等待后端校验后再反映。
    return false;
  }

  /// 回退兼容：从服务端重新拉取权益。
  Future<bool> restore() => refresh();

  /// 从服务端拉取当前用户权益并落地（登录 / 回到前台 / 网络恢复时调用）。
  Future<bool> refresh() async {
    if (!_isSignedIn()) return false;
    final verified = await _verifier.verifyRestore();
    if (verified != null) {
      await _entitlement.applyServer(verified);
      return true;
    }
    return false;
  }

  static String _skuFor(MembershipTier t) {
    switch (t) {
      case MembershipTier.monthly:
        return 'premium_monthly';
      case MembershipTier.yearly:
        return 'premium_yearly';
      case MembershipTier.lifetime:
        return 'premium_lifetime';
      case MembershipTier.vipMonthly:
        return 'vip_monthly';
      case MembershipTier.vipYearly:
        return 'vip_yearly';
      case MembershipTier.vipLifetime:
        return 'vip_lifetime';
      default:
        return '';
    }
  }
}
