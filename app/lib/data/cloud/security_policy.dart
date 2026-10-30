import 'dart:io';

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
    if (!appChannel.canSelfUpdate) return false; // store = HTTPS only, always
    final h = uri.host;
    if (h == '127.0.0.1' || h == 'localhost' || h == '::1') return true;
    final p = h.split('.');
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
