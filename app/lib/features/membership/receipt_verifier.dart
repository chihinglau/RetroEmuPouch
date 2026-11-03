import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart' show kDebugMode;

import '../account/account_backend.dart' show kAccountBaseUrl, kAccountToken, AccountStore;
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

/// Real backend receipt verification (debug / 联调 专用).
///
/// Calls `POST /api/billing/verify` with `X-Dev-Mock: 1` so the server grants
/// the entitlement for [sku] without a real store purchase, and returns the
/// authoritative [Entitlement]. The client never decides entitlement truth.
///
/// Only selected by [Membership] when `kDebugMode && real backend enabled`;
/// release builds keep the NoOp verifier.
class HttpReceiptVerifier implements ReceiptVerifier {
  HttpReceiptVerifier(this._store);
  final AccountStore _store;

  @override
  Future<Entitlement?> verifyPurchase({
    required String sku,
    required String token,
  }) async {
    final base = (_store.getString(kAccountBaseUrl) ?? '').trim();
    final auth = _store.getString(kAccountToken) ?? '';
    if (base.isEmpty) return null;
    final uri = Uri.parse('$base/api/billing/verify');
    final client = HttpClient()..connectionTimeout = const Duration(seconds: 8);
    if (kDebugMode && _acceptDebugCert(uri.host)) {
      // dart:io 的 TLS 栈不认用户 CA；debug 联调对回环/私网放行自签证书（自签 mkcert）。
      client.badCertificateCallback = (cert, host, port) => true;
    }
    try {
      final req = await client.postUrl(uri);
      req.headers.set(HttpHeaders.contentTypeHeader, 'application/json');
      req.headers.set(HttpHeaders.authorizationHeader, 'Bearer $auth');
      req.headers.set('X-Dev-Mock', '1');
      req.write(jsonEncode({
        'platform': 'android',
        'sku': sku,
        'purchase_token': token,
      }));
      final resp = await req.close();
      final body = await resp.transform(utf8.decoder).join();
      if (resp.statusCode != 200) return null;
      final j = jsonDecode(body) as Map<String, dynamic>;
      final ent = j['entitlement'] as Map<String, dynamic>?;
      if (j['ok'] != true || ent == null) return null;
      return _toEntitlement(ent);
    } catch (_) {
      return null;
    } finally {
      client.close(force: true);
    }
  }

  @override
  Future<Entitlement?> verifyRestore() async {
    final base = (_store.getString(kAccountBaseUrl) ?? '').trim();
    final auth = _store.getString(kAccountToken) ?? '';
    if (base.isEmpty) return null;
    final uri = Uri.parse('$base/api/billing/entitlement');
    final client = HttpClient()..connectionTimeout = const Duration(seconds: 8);
    if (kDebugMode && _acceptDebugCert(uri.host)) {
      client.badCertificateCallback = (cert, host, port) => true;
    }
    try {
      final req = await client.getUrl(uri);
      req.headers.set(HttpHeaders.authorizationHeader, 'Bearer $auth');
      final resp = await req.close();
      final body = await resp.transform(utf8.decoder).join();
      if (resp.statusCode != 200) return null;
      final j = jsonDecode(body) as Map<String, dynamic>;
      return _toEntitlement(j);
    } catch (_) {
      return null;
    } finally {
      client.close(force: true);
    }
  }

  Entitlement _toEntitlement(Map<String, dynamic> ent) {
    final tier = _tierFromString(ent['tier'] as String?);
    final expiry = ent['expiry_at'] as String?;
    final expireAt = expiry == null ? null : DateTime.tryParse(expiry);
    final isLifetime = ent['is_lifetime'] as bool? ?? false;
    final trial = ent['trial_start'] as String?;
    final trialStart = trial == null ? null : DateTime.tryParse(trial);
    return Entitlement(
      tier: tier,
      expireAt: expireAt,
      isLifetime: isLifetime,
      trialStart: trialStart,
    );
  }

  MembershipTier _tierFromString(String? v) {
    switch (v) {
      case 'premium_monthly':
        return MembershipTier.monthly;
      case 'premium_yearly':
        return MembershipTier.yearly;
      case 'premium_lifetime':
        return MembershipTier.lifetime;
      case 'vip_monthly':
        return MembershipTier.vipMonthly;
      case 'vip_yearly':
        return MembershipTier.vipYearly;
      case 'vip_lifetime':
        return MembershipTier.vipLifetime;
      default:
        return MembershipTier.free;
    }
  }
}

/// debug 联调时是否对自签证书放行：回环 + RFC1918 私网（开发机/局域网 https）。
/// 与 [SecurityPolicy] 的私网判定一致；仅 kDebugMode 下由调用方配合生效。
bool _acceptDebugCert(String host) {
  if (host == '127.0.0.1' || host == 'localhost' || host == '::1') return true;
  final p = host.split('.');
  if (p.length != 4) return false;
  final a = int.tryParse(p[0]);
  final b = int.tryParse(p[1]);
  if (a == null || b == null) return false;
  return a == 10 || (a == 192 && b == 168) || (a == 172 && b >= 16 && b <= 31);
}
