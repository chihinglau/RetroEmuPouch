import 'dart:convert';
import 'dart:io';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';

/// Persistent cloud connection settings stored at
/// `<filesDir>/cloud_config.json` (kept out of `rom_index.json` so the local
/// library stays usable while signed out).
///
/// R8: the session token is intentionally NOT part of that file. It lives in
/// the platform encrypted store (Android Keystore-backed
/// EncryptedSharedPreferences), so it is never recoverable from a file dump
/// or a backup export. [save] writes/removes it there and [load] reads it
/// back, migrating any legacy plaintext token it finds (one time).
class CloudConfig {
  CloudConfig({
    required this.filesDir,
    this.baseUrl = '',
    this.token,
    this.userName,
    this.role,
    this.userId,
    this.lastRevision = 0,
  });

  static final FlutterSecureStorage _secure = FlutterSecureStorage();

  /// Key under which the session token is kept in the encrypted store.
  static const String _kToken = 'cloud_token';

  final String filesDir;
  String baseUrl;
  String? token;
  String? userName;
  String? role;
  String? userId;
  int lastRevision;

  File get _file => File('$filesDir/cloud_config.json');

  bool get isLoggedIn => token != null && token!.isNotEmpty;
  bool get isConfigured => baseUrl.isNotEmpty;
  bool get isAdmin => role == 'admin';

  static String normalize(String raw) {
    var u = raw.trim();
    if (u.isEmpty) return u;
    if (!u.startsWith('http://') && !u.startsWith('https://')) {
      // R7: default to HTTPS. Plaintext is only ever permitted for loopback /
      // RFC1918 LAN (see SecurityPolicy), never for a bare public host.
      u = 'https://$u';
    }
    while (u.endsWith('/')) {
      u = u.substring(0, u.length - 1);
    }
    return u;
  }

  void setSession({required String token, required Map<String, dynamic> user}) {
    this.token = token;
    userId = user['id'] as String?;
    userName = user['name'] as String?;
    role = user['role'] as String?;
  }

  void clearSession() {
    token = null;
    userName = null;
    role = null;
    userId = null;
    lastRevision = 0;
  }

  /// Reads the token from the encrypted store. Returns null when unavailable
  /// (e.g. no plugin channel in a unit test) so callers fail closed.
  static Future<String?> _readToken() async {
    try {
      return await _secure.read(key: _kToken);
    } catch (_) {
      return null;
    }
  }

  static Future<CloudConfig> load(String filesDir) async {
    final cfg = CloudConfig(filesDir: filesDir);
    final f = cfg._file;
    String? legacyToken;
    if (f.existsSync()) {
      try {
        final j = jsonDecode(await f.readAsString()) as Map<String, dynamic>;
        cfg.baseUrl = (j['baseUrl'] as String?) ?? '';
        // Pre-R8 plaintext token: migrated below, then never written again.
        legacyToken = j['token'] as String?;
        cfg.userName = j['userName'] as String?;
        cfg.role = j['role'] as String?;
        cfg.userId = j['userId'] as String?;
        cfg.lastRevision = (j['lastRevision'] as num?)?.toInt() ?? 0;
      } catch (_) {
        // corrupt config must never block app startup
      }
    }
    cfg.token = await _readToken();
    if ((cfg.token == null || cfg.token!.isEmpty) &&
        legacyToken != null &&
        legacyToken.isNotEmpty) {
      // One-time migration: move the legacy plaintext token into the
      // encrypted store and rewrite the JSON without it.
      cfg.token = legacyToken;
      await cfg.save();
    }
    return cfg;
  }

  Future<void> save() async {
    // R8: persist the session token in the encrypted store only. On failure we
    // fail closed (token simply not persisted) rather than writing plaintext.
    try {
      if (token == null || token!.isEmpty) {
        await _secure.delete(key: _kToken);
      } else {
        await _secure.write(key: _kToken, value: token!);
      }
    } catch (_) {
      // Keystore / channel unavailable — never fall back to plaintext.
    }
    await _file.parent.create(recursive: true);
    final payload = const JsonEncoder.withIndent('  ').convert({
      'baseUrl': baseUrl,
      // 'token' deliberately omitted — it lives in the encrypted store.
      'userName': userName,
      'role': role,
      'userId': userId,
      'lastRevision': lastRevision,
    });
    await _file.writeAsString(payload, flush: true);
  }
}
