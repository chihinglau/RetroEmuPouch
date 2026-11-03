import 'package:flutter/foundation.dart';

import '../../config/app_channel.dart';

/// Centralised outbound-request security policy (P0-2, R7).
///
/// Every request built by [CloudClient] is vetted through [assertSafe], so this
/// is the single choke-point that decides what connections are allowed.
class SecurityPolicy {
  /// The only plaintext (http://) traffic we ever permit is loopback or an
  /// RFC1918 private LAN, and then only on the `community` channel (local
  /// sideload / a home server on the user's own network). Store builds must use
  /// HTTPS for everything — there is no plaintext exception.
  static bool allowsCleartext(Uri uri) {
    if (uri.scheme != 'http') return false;
    if (!appChannel.canSelfUpdate) {
      // store 渠道默认禁止明文；但 debug 联调（真机连局域网开发服务器）时对
      // RFC1918 私网放行明文，避免开发者只能改用 https 自签。release 不受影响。
      if (!kDebugMode) return false;
      return _isPrivateLan(uri.host);
    }
    final h = uri.host;
    if (h == '127.0.0.1' || h == 'localhost' || h == '::1') return true;
    return _isPrivateLan(h);
  }

  /// RFC1918 私网地址（10/8、192.168/16、172.16-31/12）。
  static bool _isPrivateLan(String host) {
    final p = host.split('.');
    if (p.length != 4) return false;
    final a = int.tryParse(p[0]);
    final b = int.tryParse(p[1]);
    if (a == null || b == null) return false;
    return a == 10 || (a == 192 && b == 168) || (a == 172 && b >= 16 && b <= 31);
  }

  /// Throws [SecurityException] for any connection the policy forbids.
  static void assertSafe(Uri uri) {
    if (uri.scheme == 'http' && !allowsCleartext(uri)) {
      throw const SecurityException('拒绝不安全的明文连接，请使用 HTTPS（或仅限局域网）');
    }
  }
}

class SecurityException implements Exception {
  const SecurityException(this.message);
  final String message;
  @override
  String toString() => 'SecurityException: $message';
}
